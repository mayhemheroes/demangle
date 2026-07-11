// Copyright 2026 mayhemheroes integration. Additive Mayhem fuzz harness.
//
//go:build gofuzz

// This file provides SELF-CONTAINED native Go fuzz harnesses for the OSS-Fuzz/Mayhem build.
//
// The UPSTREAM tree already ships fuzz_test.go with FuzzDemangle / FuzzRustDemangle, but those
// functions build their seed corpora from TEST-ONLY symbols (demanglerTests, getOptLine,
// readCases, the testdata/* fixtures, ...) that live in *_test.go files. go-118-fuzz-build
// (compile_native_go_fuzzer's NATIVE path) rewrites the harness into a NON-test build where those
// symbols do not exist, so the upstream harnesses cannot be compiled that way. The OSS-Fuzz
// project sidesteps this with a tiny self-contained `FuzzTest` wrapper around ToString.
//
// We do the same here, but keep the two-target split (C++/Itanium vs Rust) so each Mayhem job has
// a focused corpus. Both exercise demangle.ToString — exactly the surface the OSS-Fuzz FuzzTest
// target fuzzes. Seed corpora are supplied externally via mayhem/testsuite/<target>/ (real mangled
// symbols harvested from testdata/demangle-expected and testdata/rust-demangle-expected).
//
// We use the STANDARD library testing.F / testing.T types: go-118-fuzz-build textually rewrites
// them to its shim at build time (register.go blank-imports the shim into the module graph). The
// `//go:build gofuzz` tag means this file is compiled ONLY by the fuzz builder
// (go-118-fuzz-build -tags gofuzz); it is invisible to the project's normal `go test ./...`, so it
// never collides with the upstream fuzz_test.go and never affects the test oracle.

package demangle

import (
	"testing"
)

// FuzzCpp drives arbitrary input through the C++/Itanium-and-friends demangler entrypoint.
func FuzzCpp(f *testing.F) {
	f.Fuzz(func(t *testing.T, in string) {
		_, _ = ToString(in)
	})
}

// FuzzRust drives arbitrary input through the same demangler entrypoint with a Rust-flavoured
// seed corpus. ToString auto-detects Rust v0/legacy mangling, so the same call covers it.
func FuzzRust(f *testing.F) {
	f.Fuzz(func(t *testing.T, in string) {
		_, _ = ToString(in)
	})
}
