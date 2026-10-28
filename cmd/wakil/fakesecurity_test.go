package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestMain points `security` at a script that answers "no such item" for every test in this
// package, so no test reaches the real login keychain. A test that needs another answer sets
// WAKIL_SECURITY_BINARY itself.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "wakil-fake-security")
	if err != nil {
		panic(err)
	}
	path := filepath.Join(dir, "security")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 44\n"), 0o755); err != nil {
		panic(err)
	}
	os.Setenv("WAKIL_SECURITY_BINARY", path)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
