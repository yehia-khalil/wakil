package wakilcore_test

import (
	"bufio"
	"go/build"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// violation says why package pkg importing imp breaks the module's layering, or "".
// Rules: internal/... never imports cmd/...; internal/wakilcore, the base every
// other package builds on, imports no other package of this module.
func violation(module, pkg, imp string) string {
	in := func(p, dir string) bool { return p == module+"/"+dir || strings.HasPrefix(p, module+"/"+dir+"/") }
	if in(pkg, "internal") && in(imp, "cmd") {
		return pkg + " imports a command: " + imp
	}
	if in(pkg, "internal/wakilcore") && strings.HasPrefix(imp, module+"/") && !in(imp, "internal/wakilcore") {
		return pkg + " is the base package but imports " + imp
	}
	return ""
}

func TestLayeringRulesCatchWhatTheyShould(t *testing.T) {
	m := "example.com/x"
	cases := []struct {
		pkg, imp string
		bad      bool
	}{
		{m + "/internal/wakilcore", m + "/cmd/wakil", true},
		{m + "/internal/wakilcore", m + "/internal/mcpx", true},
		{m + "/internal/wakilcore", m + "/internal/mcpx/mcpxtest", true},
		{m + "/internal/mcpx", m + "/internal/wakilcore", false},
		{m + "/internal/mcpx/mcpxtest", m + "/internal/wakilcore", false},
		{m + "/cmd/wakil", m + "/internal/wakilcore", false},
		{m + "/internal/wakilcore", "strings", false},
	}
	for _, c := range cases {
		if got := violation(m, c.pkg, c.imp) != ""; got != c.bad {
			t.Errorf("violation(%s -> %s) = %v, want %v", c.pkg, c.imp, got, c.bad)
		}
	}
}

func TestModuleKeepsItsLayering(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	module := modulePath(t, filepath.Join(root, "go.mod"))
	for _, top := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, top), func(path string, d fs.DirEntry, err error) error {
			if err != nil || !d.IsDir() {
				return err
			}
			if d.Name() == "testdata" {
				return filepath.SkipDir
			}
			p, err := build.ImportDir(path, 0)
			if err != nil {
				if _, ok := err.(*build.NoGoError); ok {
					return nil
				}
				return err
			}
			rel, _ := filepath.Rel(root, path)
			pkg := module + "/" + filepath.ToSlash(rel)
			for _, imp := range append(append(append([]string{}, p.Imports...), p.TestImports...), p.XTestImports...) {
				if v := violation(module, pkg, imp); v != "" {
					t.Error(v)
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func modulePath(t *testing.T, goMod string) string {
	f, err := os.Open(goMod)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if line := strings.TrimSpace(s.Text()); strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "module "))
		}
	}
	t.Fatal("no module line in go.mod")
	return ""
}
