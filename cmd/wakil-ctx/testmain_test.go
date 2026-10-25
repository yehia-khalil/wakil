package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain points the Keychain tool at a stand-in that accepts every write and finds nothing,
// so no test here can reach the operator's login keychain, however the tree or a tool reads
// it. A test that wants items to stay (memorySecurity) sets its own over this.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "wakil-ctx-security")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	script := filepath.Join(dir, "security")
	body := "#!/bin/sh\ncase \"$1\" in add-generic-password|delete-generic-password) exit 0;; esac\nexit 44\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Setenv("WAKIL_SECURITY_BINARY", script)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
