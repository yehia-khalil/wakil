package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type listArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
}
type listDirArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Dir  string `json:"dir" jsonschema:"a folder inside root, relative and slash-separated"`
}
type searchArg struct {
	Roots []string `json:"roots,omitempty" jsonschema:"roots to search (absolute, each a root of the active project); all of them when empty"`
	Query string   `json:"query" jsonschema:"the text to find"`
	Case  bool     `json:"case,omitempty" jsonschema:"true for a case-sensitive search"`
	Word  bool     `json:"word,omitempty" jsonschema:"true to match whole words only"`
	Regex bool     `json:"regex,omitempty" jsonschema:"true to read query as a Go regular expression"`
}
type replaceTextArg struct {
	Texts       []string `json:"texts" jsonschema:"the texts to replace in, each whole; answered in order"`
	Query       string   `json:"query" jsonschema:"the text to find"`
	Case        bool     `json:"case,omitempty" jsonschema:"true for a case-sensitive match"`
	Word        bool     `json:"word,omitempty" jsonschema:"true to match whole words only"`
	Regex       bool     `json:"regex,omitempty" jsonschema:"true to read query as a Go regular expression"`
	Replacement string   `json:"replacement" jsonschema:"what each match becomes; with regex, $1, ${name} and $$ expand as Go's regexp.Expand reads them"`
}
type replaceArg struct {
	Roots       []string `json:"roots,omitempty" jsonschema:"roots to replace in (absolute, each a root of the active project); all of them when empty"`
	Query       string   `json:"query" jsonschema:"the text to find"`
	Case        bool     `json:"case,omitempty" jsonschema:"true for a case-sensitive match"`
	Word        bool     `json:"word,omitempty" jsonschema:"true to match whole words only"`
	Regex       bool     `json:"regex,omitempty" jsonschema:"true to read query as a Go regular expression"`
	Replacement string   `json:"replacement" jsonschema:"what each match becomes; with regex, $1, ${name} and $$ expand as Go's regexp.Expand reads them"`
	Only        string   `json:"only,omitempty" jsonschema:"one file (absolute): replace in it alone"`
	Skip        []string `json:"skip,omitempty" jsonschema:"files (absolute) to leave on disk; those the search covers come back in skipped"`
	After       string   `json:"after,omitempty" jsonschema:"a previous call's next: resume after it"`
	MaxFiles    int      `json:"max_files,omitempty" jsonschema:"stop after writing this many files, or after 250 ms; next resumes"`
}

type readArg struct {
	Path string `json:"path" jsonschema:"absolute path of a file inside one of the active project's roots"`
	From *int   `json:"from,omitempty" jsonschema:"byte offset: answer only the whole lines after it (a growing log)"`
}
type writeArg struct {
	Path   string `json:"path" jsonschema:"absolute path of a file inside one of the active project's roots"`
	Text   string `json:"text" jsonschema:"the whole new contents, written as given (line endings kept)"`
	Create bool   `json:"create" jsonschema:"true to create the file (and missing folders inside the root) if absent"`
}
type createArg struct {
	Path string `json:"path" jsonschema:"absolute path of the new file or folder, inside one of the active project's roots"`
	Kind string `json:"kind" jsonschema:"file or dir"`
}
type moveArg struct {
	From string `json:"from" jsonschema:"absolute path of the file or folder to move, inside the roots"`
	To   string `json:"to" jsonschema:"its new absolute path, inside the roots"`
}
type trashArg struct {
	Path string `json:"path" jsonschema:"absolute path of the file or folder to move to the Trash, inside the roots"`
}

// project answers the active project's roots and its heavy folder names (.git, then the
// project's list — 3b-v part 2), or the tool error saying why there are none.
func project() ([]string, []string, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, nil, mcpx.ToolErr("wakil-files", err)
	}
	return wakilcore.ProjectRootPaths(*r), wakilcore.HeavyNames(r.Project.Editor.Resolved().HeavyFolders), nil
}

// roots answers the active project's roots, or the tool error saying why there are none.
func roots() ([]string, *mcp.CallToolResult) {
	rs, _, fail := project()
	return rs, fail
}

func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-files", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "files_list", Description: "Read-only. One root's files, relative and sorted: in a repository git's tracked and untracked files (files), its gitignored files outside the heavy folders (ignored), and the heavy folders — .git and the project's list, by default vendor and node_modules (heavy, never walked); otherwise a walk that lists each child repository the same way (repos) and reports the walk's skipped folders as heavy. files and ignored together are capped at 50,000, tracked first; truncated says so."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a listArg) (*mcp.CallToolResult, wakilcore.FileList, error) {
			rs, heavy, fail := project()
			if fail != nil {
				return fail, wakilcore.FileList{}, nil
			}
			l, err := wakilcore.ListFiles(ctx, a.Root, rs, heavy)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileList{}, nil
			}
			return nil, l, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_list_dir", Description: "Read-only. One folder's direct entries ({name, kind: file|dir}), folders first, each sorted — how a heavy folder opens. dir is relative to root. Confined to the active project's roots (Invariant 6, Decision 36)."},
		func(_ context.Context, _ *mcp.CallToolRequest, a listDirArg) (*mcp.CallToolResult, wakilcore.DirList, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.DirList{}, nil
			}
			d, err := wakilcore.ListDir(a.Root, a.Dir, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.DirList{}, nil
			}
			return nil, d, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_search", Description: "Read-only. Searches the project's files for query (literal unless regex; case-insensitive unless case; whole words with word): each match's root, path (relative), line, column (1-based, UTF-16) and the matching line as preview. Ignored files and the heavy folders are skipped, as are binary files and files over 2 MB (named in skipped_large). Stops at 2,000 matches (truncated); files_truncated says a root had more than 50,000 files and was searched only in part. Links to files outside the roots are skipped. An invalid regex is Go's own error."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a searchArg) (*mcp.CallToolResult, wakilcore.SearchResult, error) {
			rs, heavy, fail := project()
			if fail != nil {
				return fail, wakilcore.SearchResult{}, nil
			}
			r, err := wakilcore.SearchFiles(ctx, rs, heavy, a.Roots, wakilcore.SearchQuery{Query: a.Query, Case: a.Case, Word: a.Word, Regex: a.Regex})
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.SearchResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_replace_text", Description: "Read-only. Each of texts with every match of query replaced — the pattern files_search uses, line by line — answering per text its new text, count and edits (each replacement's UTF-16 span start..end in the old text, and its text). Touches no file."},
		func(_ context.Context, _ *mcp.CallToolRequest, a replaceTextArg) (*mcp.CallToolResult, wakilcore.ReplaceTextsResult, error) {
			r, err := wakilcore.ReplaceTexts(a.Texts, wakilcore.SearchQuery{Query: a.Query, Case: a.Case, Word: a.Word, Regex: a.Regex}, a.Replacement)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.ReplaceTextsResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_replace", Description: "Writes every match of query, replaced, in the files files_search covers (ignored, heavy, binary and over-2 MB files skipped), each file whole and atomically, keeping its mode. Files in skip are left on disk and those covered are listed in skipped; only names one file. Answers each written file's path, count, original text and mtime, the files that failed with their error, and truncated_files. With max_files it stops early and next resumes it; a cancelled call stops between files with what it wrote (cancelled). Confined to the active project's roots (Invariant 6, Decision 36, Decision 39)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a replaceArg) (*mcp.CallToolResult, wakilcore.ReplaceResult, error) {
			rs, heavy, fail := project()
			if fail != nil {
				return fail, wakilcore.ReplaceResult{}, nil
			}
			r, err := wakilcore.ReplaceFiles(ctx, rs, heavy, wakilcore.SearchQuery{Query: a.Query, Case: a.Case, Word: a.Word, Regex: a.Regex},
				a.Replacement, wakilcore.ReplaceOptions{Roots: a.Roots, Only: a.Only, Skip: a.Skip, After: a.After, MaxFiles: a.MaxFiles})
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.ReplaceResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_read", Description: "Read-only. One file's text, size and mtime (Unix ns). Over 2 MB, the last 2 MB from a line start (tail, over_cap, start). With from (a byte offset), only the whole lines after it, end the offset after them; shrunk when the file is now shorter than from, too_far when more than 2 MB lie past it. No text for a binary file (binary) or a file that is not UTF-8 (utf8 false); exists false for a missing file; a FIFO, socket or device is refused. Confined to the active project's roots."},
		func(_ context.Context, _ *mcp.CallToolRequest, a readArg) (*mcp.CallToolResult, wakilcore.FileRead, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileRead{}, nil
			}
			var r wakilcore.FileRead
			var err error
			if a.From != nil {
				r, err = wakilcore.ReadFileFrom(a.Path, *a.From, rs)
			} else {
				r, err = wakilcore.ReadFile(a.Path, rs)
			}
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileRead{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "files_write", Description: "Writes one file's whole text, atomically. create false refuses a missing file. Confined to the active project's roots (Invariant 6, Decision 36). Rename, move and delete are files_move and files_trash."},
		func(_ context.Context, _ *mcp.CallToolRequest, a writeArg) (*mcp.CallToolResult, wakilcore.FileWritten, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileWritten{}, nil
			}
			w, err := wakilcore.WriteFile(a.Path, a.Text, a.Create, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileWritten{}, nil
			}
			return nil, w, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "files_create", Description: "Makes an empty file or a folder (kind file or dir), and missing folders above it. An existing name is refused, never overwritten. Confined to the active project's roots (Invariant 6, Decision 41)."},
		func(_ context.Context, _ *mcp.CallToolRequest, a createArg) (*mcp.CallToolResult, wakilcore.FileEntry, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileEntry{}, nil
			}
			e, err := wakilcore.CreateEntry(a.Path, a.Kind, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileEntry{}, nil
			}
			return nil, e, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "files_move", Description: "Renames or moves a file or folder (a link as itself), making missing folders above to. An existing to is refused; a case-only rename works; the same name is ignored; a root is never moved; a move across volumes is refused. Confined to the active project's roots (Invariant 6, Decision 41)."},
		func(_ context.Context, _ *mcp.CallToolRequest, a moveArg) (*mcp.CallToolResult, wakilcore.FileMoved, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileMoved{}, nil
			}
			m, err := wakilcore.MoveEntry(a.From, a.To, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileMoved{}, nil
			}
			return nil, m, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "files_trash", Description: "Moves a file or folder (a link as itself) to the user's Trash, where Finder's Put Back restores it; needs macOS 15's /usr/bin/trash. A root is never trashed. Confined to the active project's roots (Invariant 6, Decision 41)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a trashArg) (*mcp.CallToolResult, wakilcore.FileEntry, error) {
			rs, fail := roots()
			if fail != nil {
				return fail, wakilcore.FileEntry{}, nil
			}
			e, err := wakilcore.TrashEntry(ctx, a.Path, rs)
			if err != nil {
				return mcpx.ToolErr("wakil-files", err), wakilcore.FileEntry{}, nil
			}
			return nil, e, nil
		})
	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
