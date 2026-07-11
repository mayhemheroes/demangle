#!/usr/bin/env bash
#
# demangle/mayhem/test.sh — RUN ianlancetaylor/demangle's OWN Go test suite (`go test ./...`)
# and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: demangle's suite is a REAL known-answer suite — demangle_test.go,
# expected_test.go and rust_expected_test.go drive HUNDREDS of mangled-symbol -> demangled-string
# cases from the tables and from testdata/demangle-expected, testdata/rust-demangle-expected,
# testdata/rust.test and the LLVM DemangleTestCases.inc, asserting the demangler's BEHAVIOUR
# (each input must produce the exact expected output). A no-op / `return ""` patch FAILS this
# oracle.
#
# Anti-reward-hacking behavioral probe (§6.3): after running go test (which is statically linked
# and thus immune to the LD_PRELOAD sabotage mechanism), this script also executes
# /mayhem/FuzzDemangle (dynamically linked, ASan+libFuzzer) against a known corpus entry and
# asserts specific libFuzzer output strings ("Executed ... in"). A no-op / exit(0) PATCH to
# demangle's parser leaves FuzzDemangle intact (it IS the compiled Go parser), so it still emits
# the expected output. When the SABOTAGE MECHANISM (LD_PRELOAD _exit(0)) neuters FuzzDemangle
# itself, FuzzDemangle exits silently and the grep fails — proving the oracle detects sabotage
# (not reward-hackable).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
# -json gives machine-parseable per-test events; mirror stdout for humans via a separate pass.
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test ./... 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — they are
# real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked FuzzDemangle binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/FuzzDemangle IS dynamically linked (built with clang+ASan). Run it single-shot against a
# known corpus entry and assert that libFuzzer emits "Executed" — proving it actually processed
# the input. The sabotage LD_PRELOAD neuters FuzzDemangle (not in /usr/bin etc.), causing it to
# exit silently → the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/FuzzDemangle/testsuite/seed_00"
if [ -x /mayhem/FuzzDemangle ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: FuzzDemangle single-shot on known corpus ==="
  PROBE_OUT=$(/mayhem/FuzzDemangle "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: FuzzDemangle executed the corpus input (demangler active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: FuzzDemangle produced no 'Executed' output (demangler inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
