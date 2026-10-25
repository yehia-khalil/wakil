package wakilcore

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain points the Keychain tool at a stand-in that accepts every write and finds nothing,
// so no test here can reach the operator's login keychain, however a tree or a record reads
// it. A test that needs to see its calls sets securityBinary (fakeSecurity) or
// WAKIL_SECURITY_BINARY over this.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "wakilcore-security")
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
	securityBinary = keychainTool(script)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
