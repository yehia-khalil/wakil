package wakilcore

import (
	"context"
	"strconv"
	"strings"
)

// GitFile describes one change at one path.
type GitFile struct {
	Path     string `json:"path"`
	OrigPath string `json:"origPath,omitempty"` // a rename's old path
	Group    string `json:"group"`              // "staged" | "changed" | "untracked"
	Status   string `json:"status"`             // one letter: M A D R C T U ?
}

// GitStatus describes a git working tree: its branch, commit, relation to upstream,
// and changed files.
type GitStatus struct {
	Root     string    `json:"root"`
	Branch   string    `json:"branch"`   // "" when detached
	Detached string    `json:"detached"` // short SHA when detached
	Upstream string    `json:"upstream"`
	Ahead    int       `json:"ahead"`
	Behind   int       `json:"behind"`
	Files    []GitFile `json:"files"`
}

// ParseGitStatus reads `git status --porcelain=v2 -z --branch`. Entries are
// NUL-separated; a rename (`2`) carries its original path as the NEXT entry.
func ParseGitStatus(root string, porcelain []byte) GitStatus {
	st := GitStatus{Root: root, Files: []GitFile{}}
	entries := strings.Split(string(porcelain), "\x00")
	var oid string
	for i := 0; i < len(entries); i++ {
		e := entries[i]
		switch {
		case strings.HasPrefix(e, "# branch.oid "):
			oid = strings.TrimPrefix(e, "# branch.oid ")
		case strings.HasPrefix(e, "# branch.head "):
			if h := strings.TrimPrefix(e, "# branch.head "); h != "(detached)" {
				st.Branch = h
			} else if len(oid) >= 7 {
				st.Detached = oid[:7]
			}
		case strings.HasPrefix(e, "# branch.upstream "):
			st.Upstream = strings.TrimPrefix(e, "# branch.upstream ")
		case strings.HasPrefix(e, "# branch.ab "):
			f := strings.Fields(strings.TrimPrefix(e, "# branch.ab "))
			if len(f) == 2 {
				st.Ahead, _ = strconv.Atoi(strings.TrimPrefix(f[0], "+"))
				st.Behind, _ = strconv.Atoi(strings.TrimPrefix(f[1], "-"))
			}
		case strings.HasPrefix(e, "1 "), strings.HasPrefix(e, "u "):
			// 1 XY sub mH mI mW hH hI path   (8 fields before path)
			// u XY sub m1 m2 m3 mW h1 h2 h3 path (10 fields before path)
			n := 8
			if e[0] == 'u' {
				n = 10
			}
			parts := strings.SplitN(e, " ", n+1)
			switch {
			case len(parts) != n+1:
			case e[0] == 'u':
				// R13: a conflict is one Changes row, U, whatever its XY (UU, AA, DU…):
				// the pane diffs it HEAD against the working tree, where the markers are.
				st.Files = append(st.Files, GitFile{Path: parts[n], Group: "changed", Status: "U"})
			default:
				st.Files = append(st.Files, filesFor(parts[1], parts[n], "")...)
			}
		case strings.HasPrefix(e, "2 "):
			// 2 XY sub mH mI mW hH hI Xscore path, then origPath as next entry
			parts := strings.SplitN(e, " ", 10)
			if len(parts) == 10 && i+1 < len(entries) {
				st.Files = append(st.Files, filesFor(parts[1], parts[9], entries[i+1])...)
				i++
			}
		case strings.HasPrefix(e, "? "):
			st.Files = append(st.Files, GitFile{Path: e[2:], Group: "untracked", Status: "?"})
		}
	}
	return st
}

// filesFor turns one XY pair into its rows: X is the index side (staged),
// Y the work-tree side (changed). A file with both is two rows.
func filesFor(xy, path, orig string) []GitFile {
	var out []GitFile
	if x := xy[0]; x != '.' {
		f := GitFile{Path: path, Group: "staged", Status: string(x)}
		if x == 'R' || x == 'C' {
			f.OrigPath = orig
		}
		out = append(out, f)
	}
	if y := xy[1]; y != '.' {
		out = append(out, GitFile{Path: path, Group: "changed", Status: string(y)})
	}
	return out
}

// ReadGitStatus runs `git status --porcelain=v2 -z --branch` and parses the result.
func ReadGitStatus(ctx context.Context, g *GitRunner) (GitStatus, error) {
	out, err := g.Run(ctx, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
	if err != nil {
		return GitStatus{Root: g.Root, Files: []GitFile{}}, err
	}
	return ParseGitStatus(g.Root, out), nil
}
