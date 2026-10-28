package wakilcore

import (
	"bytes"
	"errors"
	"os/exec"
)

// browserLoginRef is the Keychain ref of the default identity's saved browser passwords.
const browserLoginRef = "browser-login:default"

// BrowserLoginsPresent reports whether the organisation's default identity still has saved browser
// passwords in the Keychain. It reads attributes only: no -w, no -g, so no value is returned and no
// prompt is raised. Exit 44 (no such item) is false, not an error; any other failure is a UserError.
func BrowserLoginsPresent(org string) (bool, error) {
	service, err := keychainService(org, browserLoginRef)
	if err != nil {
		return false, err
	}
	cmd := keychainCommand("find-generic-password", "-s", service)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == keychainNotFoundExitCode {
			return false, nil
		}
		return false, UserError("could not look for saved browser passwords in org " + org + ": " + diagnostic(err, &stderr))
	}
	return true, nil
}
