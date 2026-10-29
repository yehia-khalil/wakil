package wakilcore

import "testing"

func TestSetJiraTokenRefusesAnEmptyPartOrAColon(t *testing.T) {
	for _, c := range [][2]string{{"", "t"}, {"a@initech.test", ""}, {"a:b@initech.test", "t"}, {"  ", "t"}} {
		err := SetJiraToken("initech", c[0], c[1])
		if _, ok := IsUserError(err); !ok {
			t.Errorf("SetJiraToken(%q, %q) = %v, want a UserError", c[0], c[1], err)
		}
	}
}
