package driver

import (
	"reflect"
	"testing"
)

// TestExpandParamsReachesTheTokenWhereverItIs. Params are arbitrary JSON and a
// path can travel inside an object or an array, so a top-level-only
// substitution would satisfy today's two callers and quietly fail the first
// one that nests.
func TestExpandParamsReachesTheTokenWhereverItIs(t *testing.T) {
	got := ExpandParams(map[string]interface{}{
		"projectPath": FixtureRootToken + "/e2e-project/.wakil/project.json",
		"nested":      map[string]interface{}{"path": FixtureRootToken + "/inner"},
		"list":        []interface{}{FixtureRootToken + "/one", "untouched"},
		"number":      float64(3),
		"flag":        true,
	}, "/tmp/fixture-root")

	want := map[string]interface{}{
		"projectPath": "/tmp/fixture-root/e2e-project/.wakil/project.json",
		"nested":      map[string]interface{}{"path": "/tmp/fixture-root/inner"},
		"list":        []interface{}{"/tmp/fixture-root/one", "untouched"},
		"number":      float64(3),
		"flag":        true,
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("expanded to %#v\nwant %#v", got, want)
	}
}

// TestExpandParamsLeavesEverythingAloneWithoutAFixture. The unit tests build a
// Runner with no fixture; a check naming the token there must fail on the path
// it actually sent rather than on a silent expansion to nothing, which would
// read as the action refusing a perfectly good path.
func TestExpandParamsLeavesEverythingAloneWithoutAFixture(t *testing.T) {
	params := map[string]interface{}{"projectPath": FixtureRootToken + "/p.json"}

	got := ExpandParams(params, "")

	if got["projectPath"] != FixtureRootToken+"/p.json" {
		t.Errorf("projectPath = %v; want the token left intact", got["projectPath"])
	}
}

// TestExpandParamsDoesNotMutateTheCheck. A check is run once here, but the
// steps are parsed once and a run that rewrote them in place would hand a
// second run — or a retry of the same file — a path already expanded against
// somebody else's fixture.
func TestExpandParamsDoesNotMutateTheCheck(t *testing.T) {
	params := map[string]interface{}{
		"projectPath": FixtureRootToken + "/p.json",
		"nested":      map[string]interface{}{"path": FixtureRootToken},
	}

	ExpandParams(params, "/tmp/first")

	if params["projectPath"] != FixtureRootToken+"/p.json" {
		t.Errorf("the original was rewritten: %v", params["projectPath"])
	}
	nested := params["nested"].(map[string]interface{})
	if nested["path"] != FixtureRootToken {
		t.Errorf("a nested original was rewritten: %v", nested["path"])
	}
}

// TestExpandParamsSurvivesNoParams — `dispatch` steps routinely carry `{}` or
// nothing at all.
func TestExpandParamsSurvivesNoParams(t *testing.T) {
	if got := ExpandParams(nil, "/tmp/root"); got != nil {
		t.Errorf("nil params expanded to %#v", got)
	}
	if got := ExpandParams(map[string]interface{}{}, "/tmp/root"); len(got) != 0 {
		t.Errorf("empty params expanded to %#v", got)
	}
}
