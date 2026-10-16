package wakilcore

// named is anything an environment holds several of, told apart by a name
// the operator wrote in project.json.
type named interface {
	Database | ApiConfig
}

// pickMessages is one resolver's four refusals.
//
// **The wording stays per-caller on purpose.** "no database named billing"
// and "no api entry named billing" send an operator to different lines of
// project.json, and `wakil-db`'s tests pin the database phrasing — which is
// not this change's to alter. What is shared is the LOGIC, which is the part
// that had to agree.
type pickMessages struct {
	noneConfigured string
	nameOneOfThem  string
	notFound       func(name string) string
	ambiguous      func(name string) string
}

// pickNamed resolves one entry of `items` by `name`.
//
// **PickDatabase and PickAPI were line-for-line identical**, and each one's
// comment argued the two had to behave the same way — a claim two
// implementations can only agree to keep, and one a reader has to diff to
// check. They share this now, so the agreement is structural.
//
// `name` may be empty only when there is exactly one entry. With more than
// one an empty name is ambiguous and is rejected rather than guessed at, and
// a name matching more than one entry is rejected rather than resolved to
// whichever comes first in the slice. For a database that silent resolution
// is a configuration error the caller never learns about; for an API entry
// it is also one backend's credential sent to another backend's host.
func pickNamed[T named](items []T, name string, nameOf func(T) string, msg pickMessages) (T, error) {
	var zero T
	if len(items) == 0 {
		return zero, UserError(msg.noneConfigured)
	}
	if name == "" {
		if len(items) == 1 {
			return items[0], nil
		}
		return zero, UserError(msg.nameOneOfThem)
	}
	var match *T
	count := 0
	for i := range items {
		if nameOf(items[i]) == name {
			count++
			match = &items[i]
		}
	}
	switch count {
	case 0:
		return zero, UserError(msg.notFound(name))
	case 1:
		return *match, nil
	default:
		return zero, UserError(msg.ambiguous(name))
	}
}
