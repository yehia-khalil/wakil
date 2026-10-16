package driver

import "strings"

// FixtureRootToken is what a check writes where it means "this run's fixture
// root".
//
// **A check cannot hardcode the path, and the two actions that need one are
// not otherwise reachable.** Every run lays its fixture under a fresh
// directory — `/var/folders/…/wakil-e2e1855883569/` — because two runs sharing
// one would share a keychain, a HOME and a staged bundle. So the seeded
// project's file is at a different absolute path every time, and `db_set_dsn`
// and `db_remove_database` both take a `projectPath`: without this they can be
// dispatched only with a path that is wrong by construction, which tests the
// error branch and nothing else.
//
// **Only the fixture root, and only in `dispatch` and `parity` params.** A
// general templating language in a check file would be a second thing to learn
// and a place for logic to accumulate; this is one name for one value the
// check could not otherwise know. Acts and assertions take no expansion,
// because nothing an operator clicks or reads carries this path.
const FixtureRootToken = "{fixtureRoot}"

// ExpandParams replaces FixtureRootToken in every string a params map carries,
// however deeply nested.
//
// Nested because params are arbitrary JSON and a path can travel inside an
// object or an array; a top-level-only substitution would work for today's two
// callers and quietly fail the first one that nests.
//
// A root of "" leaves everything untouched: the unit tests build a Runner with
// no fixture, and a check that names the token there should fail on the path
// it actually sent rather than on a silent empty expansion.
func ExpandParams(params map[string]interface{}, root string) map[string]interface{} {
	if params == nil || root == "" {
		return params
	}
	expanded := make(map[string]interface{}, len(params))
	for key, value := range params {
		expanded[key] = expandValue(value, root)
	}
	return expanded
}

func expandValue(value interface{}, root string) interface{} {
	switch typed := value.(type) {
	case string:
		return strings.ReplaceAll(typed, FixtureRootToken, root)
	case map[string]interface{}:
		return ExpandParams(typed, root)
	case []interface{}:
		out := make([]interface{}, len(typed))
		for i, element := range typed {
			out[i] = expandValue(element, root)
		}
		return out
	default:
		return value
	}
}
