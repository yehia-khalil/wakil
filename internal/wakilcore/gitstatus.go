package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// GitFile describes one change at one path.
type GitFile struct {
	Path     string `json:"path"`
	OrigPath string `json:"origPath,omitempty"` // a rename's old path
	Group    string `json:"group"`              // "conflicts" | "staged" | "changed" | "untracked"
	Status   string `json:"status"`             // one letter: M A D R C T U ?
	Kind     string `json:"kind,omitempty"`     // a conflict's XY: UU AA DU UD AU UA DD
	Markers  bool   `json:"markers,omitempty"`  // a staged file still holding a whole conflict block
}

// GitStatus describes a git working tree: its branch, commit, relation to upstream,
// changed files, and the operation stopped part-way in it (nil when none is).
type GitStatus struct {
	Root     string    `json:"root"`
	Branch   string    `json:"branch"`         // "" when detached
	Detached string    `json:"detached"`       // short SHA when detached
	Head     string    `json:"head,omitempty"` // the head's short SHA; "" on an unborn branch
	Upstream string    `json:"upstream"`
	Ahead    int       `json:"ahead"`
	Behind   int       `json:"behind"`
	Files    []GitFile `json:"files"`
	State    *GitOp    `json:"state,omitempty"`
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
			if len(oid) >= 7 && oid != "(initial)" {
				st.Head = oid[:7]
			}
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
				// 3a-v-b: a conflict is one row of its own group, U, keeping its XY (UU, AA, DU…)
				// so the row can say which sides changed it.
				st.Files = append(st.Files, GitFile{Path: parts[n], Group: "conflicts", Status: "U", Kind: parts[1]})
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

// ReadGitStatus runs `git status --porcelain=v2 -z --branch`, parses the result, and adds the
// operation in progress and each staged file's markers flag.
func ReadGitStatus(ctx context.Context, g *GitRunner) (GitStatus, error) {
	out, err := g.Run(ctx, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
	if err != nil {
		return GitStatus{Root: g.Root, Files: []GitFile{}}, err
	}
	st := ParseGitStatus(g.Root, out)
	op, err := ReadGitOp(ctx, g)
	if err != nil {
		return st, err
	}
	if op.Kind != "" && op.Kind != "am" { // an am session is the terminal's: the UI offers nothing for it
		st.State = &op
	}
	var staged []string
	for _, f := range st.Files {
		if f.Group == "staged" && f.Status != "D" {
			staged = append(staged, f.Path)
		}
	}
	markers := stagedMarkers(ctx, g, staged)
	for i, f := range st.Files {
		if f.Group == "staged" {
			st.Files[i].Markers = markers[f.Path]
		}
	}
	return st, nil
}

// markerScanLimit: a staged file larger than this is not read for markers.
const markerScanLimit = 1 << 20

// stagedMarkers reads the staged copy of each path (up to markerScanLimit) for a whole conflict block,
// in two git calls whatever the count: a stopped merge stages every file that merged cleanly. A path's
// work-tree size is looked at first, then its blob's, so a large file is not read at all.
func stagedMarkers(ctx context.Context, g *GitRunner, paths []string) map[string]bool {
	found := map[string]bool{}
	var ask []string
	for _, p := range paths {
		if fi, err := os.Stat(filepath.Join(g.Root, filepath.FromSlash(p))); err == nil && fi.Size() > markerScanLimit {
			continue
		}
		ask = append(ask, p)
	}
	if len(ask) == 0 {
		return found
	}
	// -Z: the paths go in, and the answers come out, NUL-separated, so a name with a newline is whole.
	var in strings.Builder
	for _, p := range ask {
		in.WriteString(":" + p + "\x00")
	}
	out, err := g.RunInput(ctx, []byte(in.String()), "cat-file", "--batch-check", "-Z")
	if err != nil {
		return found
	}
	answers := strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00")
	if len(answers) != len(ask) {
		return found
	}
	var ids []string
	byID := map[string][]string{}
	for i, a := range answers {
		f := strings.Fields(a) // "<id> blob <size>", or "<input> missing"
		if len(f) != 3 || f[1] != "blob" {
			continue
		}
		if n, err := strconv.Atoi(f[2]); err != nil || n > markerScanLimit {
			continue
		}
		if byID[f[0]] == nil {
			ids = append(ids, f[0])
		}
		byID[f[0]] = append(byID[f[0]], ask[i])
	}
	if len(ids) == 0 {
		return found
	}
	out, err = g.RunInput(ctx, []byte(strings.Join(ids, "\n")+"\n"), "cat-file", "--batch")
	if err != nil {
		return found
	}
	// Each object is "<id> <type> <size>\n", its bytes, then "\n". The output is converted once and
	// sliced: converting what remains on every object is quadratic in the number of files.
	rest := string(out)
	for len(rest) > 0 {
		head, body, ok := strings.Cut(rest, "\n")
		f := strings.Fields(head)
		if !ok || len(f) != 3 {
			break
		}
		n, err := strconv.Atoi(f[2])
		if err != nil || n+1 > len(body) {
			break
		}
		if hasConflictBlock(body[:n]) {
			for _, p := range byID[f[0]] {
				found[p] = true
			}
		}
		rest = body[n+1:]
	}
	return found
}

// hasConflictBlock: a `<<<<<<<`, then a `=======`, then a `>>>>>>>` line, in that order, each marker
// at a line start and followed by a space or the line's end.
func hasConflictBlock(text string) bool {
	want := 0
	for _, l := range strings.Split(text, "\n") {
		l = strings.TrimSuffix(l, "\r")
		switch {
		case isMarker(l, "<<<<<<<"):
			want = 1
		case want == 1 && l == "=======":
			want = 2
		case want == 2 && isMarker(l, ">>>>>>>"):
			return true
		}
	}
	return false
}

func isMarker(line, marker string) bool {
	rest, ok := strings.CutPrefix(line, marker)
	return ok && (rest == "" || rest[0] == ' ')
}
