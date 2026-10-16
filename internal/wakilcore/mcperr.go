package wakilcore

import "errors"

// userError's kind, when set, is a sentinel the error also answers errors.Is for — a
// more specific message for a case callers already test by sentinel.
type userError struct {
	msg  string
	kind error
}

func (e *userError) Error() string { return e.msg }

func (e *userError) Is(target error) bool { return e.kind != nil && target == e.kind }

// UserError wraps a human-facing message safe to show verbatim.
func UserError(msg string) error { return &userError{msg: msg} }

func IsUserError(err error) (string, bool) {
	var ue *userError
	if errors.As(err, &ue) {
		return ue.msg, true
	}
	return "", false
}
