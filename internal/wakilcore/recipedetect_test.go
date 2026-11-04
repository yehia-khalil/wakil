package wakilcore

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var updateGolden = flag.Bool("update", false, "rewrite testdata/recipes/*.json from what detection answers")

// detectOptions are the machines some rows are detected on; every other row has no manager.
var detectOptions = map[string]DetectOptions{
	"runtime-versions": {Managers: []string{"mise"}},
}

// One fixture repo per row of the spec's Detect table, each with its expected draft beside it.
func TestDetectRecipeMatchesEveryFixture(t *testing.T) {
	dirs, err := os.ReadDir(filepath.Join("testdata", "recipes"))
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		seen++
		name := d.Name()
		t.Run(name, func(t *testing.T) {
			draft, err := DetectRecipe(filepath.Join("testdata", "recipes", name), detectOptions[name])
			if err != nil {
				t.Fatal(err)
			}
			got, _ := json.MarshalIndent(draft, "", "  ")
			got = append(got, '\n')
			golden := filepath.Join("testdata", "recipes", name+".json")
			if *updateGolden {
				if err := os.WriteFile(golden, got, 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(golden)
			if err != nil {
				t.Fatalf("no expected draft (run with -update and read it): %v", err)
			}
			if string(got) != string(want) {
				t.Fatalf("draft differs from %s:\n%s", golden, got)
			}
		})
	}
	if seen < 30 {
		t.Fatalf("only %d fixture repos; the Detect table has a row each", seen)
	}
}

func TestDetectRecipeEmptyFolderAndRefusals(t *testing.T) {
	d, err := DetectRecipe(t.TempDir(), DetectOptions{})
	if err != nil || !d.DoesntRun || d.Why != "an empty folder" {
		t.Fatalf("empty: %+v %v", d, err)
	}
	if _, err := DetectRecipe(filepath.Join(t.TempDir(), "nope"), DetectOptions{}); err == nil {
		t.Fatal("missing folder")
	}
	unknown := t.TempDir()
	os.WriteFile(filepath.Join(unknown, "notes.txt"), []byte("x"), 0o600)
	d, _ = DetectRecipe(unknown, DetectOptions{})
	if d.Kind != "unknown" || len(d.Questions) != 1 || !strings.Contains(d.Questions[0], "found nothing it knows how to run") {
		t.Fatalf("unknown: %+v", d)
	}
}

// Every drafted recipe is one ValidateRecipes accepts.
func TestDetectedDraftsAreValidRecipes(t *testing.T) {
	dirs, _ := os.ReadDir(filepath.Join("testdata", "recipes"))
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		draft, _ := DetectRecipe(filepath.Join("testdata", "recipes", d.Name()), detectOptions[d.Name()])
		p := Project{Name: "p", Org: "o", Roots: []Root{{Path: "/x/" + draft.Repo, RepoRun: RepoRun{Recipe: "r", DoesntRun: draft.DoesntRun}}},
			Recipes: map[string]Recipe{"r": draft.Recipe}}
		if draft.DoesntRun {
			p.Roots[0].Recipe = ""
		}
		if err := ValidateRecipes(p); err != nil {
			t.Errorf("%s: drafted recipe is not valid: %v", d.Name(), err)
		}
	}
}
