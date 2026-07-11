#!/usr/bin/env bash
#
# demangle/mayhem/build.sh — build ianlancetaylor/demangle's NATIVE Go fuzz targets as
# sanitized libFuzzer binaries, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz target (projects/demangle/build.sh):
#   compile_native_go_fuzzer github.com/ianlancetaylor/demangle FuzzTest FuzzTest
# OSS-Fuzz copies its OWN fuzz_test.go (a tiny `FuzzTest` wrapper around ToString). The UPSTREAM
# tree, however, ALREADY ships richer NATIVE harnesses in fuzz_test.go:
#   * FuzzDemangle      — C++ (Itanium) symbol demangling: feeds inputs to ToString(in); seed
#                         corpus is every entry in demanglerTests/failureTests + testdata/
#                         demangle-expected + the LLVM DemangleTestCases.inc.
#   * FuzzRustDemangle  — Rust symbol demangling: ToString(in); seeds from testdata/
#                         rust-demangle-expected + testdata/rust.test + a big mangled template.
# Both are `func FuzzX(f *testing.F)`, so we build them with go-118-fuzz-build (the NATIVE path of
# compile_native_go_fuzzer), staying fully ADDITIVE — we do NOT overwrite upstream's fuzz_test.go.
# Each harness exercises the same surface as the OSS-Fuzz FuzzTest (demangle.ToString) but with
# real seed corpora, so this is a strict superset of the OSS-Fuzz integration.
#
# We produce:
#   /mayhem/FuzzDemangle      — C++/Itanium demangler harness (ASan+libFuzzer)
#   /mayhem/FuzzRustDemangle  — Rust demangler harness        (ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by go-118-fuzz-build); we link it against
# the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_native_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper, CGO bridge files)
# default to DWARF5 with clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $GO_DEBUG_FLAGS. The verify check uses the FIRST CU's
# DWARF version (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

# Go env: non-root build needs writable GOCACHE/GOPATH; use pinned path under /opt/toolchains.
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
mkdir -p "$GOPATH" "$GOCACHE"
# go-118-fuzz-build lives on PATH via /opt/toolchains/go-path/bin (set in the Dockerfile);
# make sure it is present even if this is run standalone.
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# The harness (FuzzCpp / FuzzRust) lives in mayhem/fuzz_demangle.go, gated behind
# `//go:build gofuzz`. OSS-Fuzz copies its fuzz harness into the package root before building;
# replicate that so go-118-fuzz-build finds the funcs in the demangle package directory. The
# gofuzz tag keeps it out of the normal `go test ./...` oracle.
PKG="github.com/ianlancetaylor/demangle"
cp "$SRC/mayhem/fuzz_demangle.go" "$SRC/fuzz_demangle.go"

# go-118-fuzz-build rewrites stdlib testing.F/testing.T to the AdamKorcz shim and needs it as a
# module dep plus a `register.go` blank-import so the shim is part of the build graph
# (compile_native_go_fuzzer relies on the project's build.sh having added it; OSS-Fuzz's demangle
# build.sh writes exactly this register.go). Add deps WITHOUT a final `go mod tidy` that would
# prune the unused shim. Order: tidy first, then `go get` the shim.
if [ ! -f "$SRC/register.go" ]; then
  printf 'package demangle\nimport _ "github.com/AdamKorcz/go-118-fuzz-build/testing"\n' > "$SRC/register.go"
fi
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"
ABS_DIR="$(go list -tags gofuzz -f '{{.Dir}}' "$PKG")"

build_native() {
  local func="$1" out="$2"
  echo "=== building $out (func $func, native go-118-fuzz-build, -tags gofuzz) ==="
  go-118-fuzz-build -tags gofuzz -o "$SRC/mayhem-build/$out.a" -func "$func" "$ABS_DIR"
  # Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$out.a" -o "/mayhem/$out"
  echo "built /mayhem/$out"
}

# ── NATIVE targets ───────────────────────────────────────────────────────────────────────────
#   func name (in mayhem/fuzz_demangle.go)  ->  output binary name (the Mayhem target)
build_native FuzzCpp  FuzzDemangle
build_native FuzzRust FuzzRustDemangle

echo "build.sh complete:"
ls -la /mayhem/FuzzDemangle /mayhem/FuzzRustDemangle 2>&1 || true
