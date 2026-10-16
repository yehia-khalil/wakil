package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// SelectionDir holds the selection record, under the evidence root, beside
// the run records the runbook reads it with.
const SelectionDir = "select"

// SelectContext is how many unchanged lines around each change count as
// changed. Zero misses an edit inside a function whose identifiers sit a few
// lines away; a whole file selects through every name a hub file such as
// WindowModel.swift spells, which is nearly every check.
var SelectContext = 3

// ChangedFiles reads what the branch changed since base: for each file, the
// changed lines and SelectContext lines around them, as they read at the base
// (Before) and at HEAD (After).
//
// **Both sides, always.** An identifier the branch removed lives only in the
// base text, and the checks that press it are exactly the ones the change
// breaks.
//
// **The hunks, not the files.** Measured on 3b-v part 2: reading whole files
// selected 95 of 127 checks, because the hub files spell almost every action.
func ChangedFiles(repo, base string) ([]ChangedFile, error) {
	out, err := exec.Command("git", "-C", repo, "diff", "--name-status", base+"...HEAD").Output()
	if err != nil {
		return nil, fmt.Errorf("listing what changed since %s: %w", ShortCommit(base), err)
	}
	var changes []ChangedFile
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) < 2 {
			continue
		}
		change := ChangedFile{Status: fields[0][:1], Path: fields[len(fields)-1]}
		patch, err := exec.Command("git", "-C", repo, "diff", fmt.Sprintf("-U%d", SelectContext),
			"--find-renames", base+"...HEAD", "--", fields[1], change.Path).Output()
		if err != nil {
			return nil, fmt.Errorf("reading the change to %s: %w", change.Path, err)
		}
		change.Before, change.After = hunkSides(string(patch))
		changes = append(changes, change)
	}
	return changes, nil
}

// hunkSides splits a unified diff into the text each side's hunks hold.
func hunkSides(patch string) (before, after string) {
	var b, a strings.Builder
	inHunk := false
	for _, line := range strings.Split(patch, "\n") {
		switch {
		case strings.HasPrefix(line, "@@"):
			inHunk = true
		case !inHunk || line == "":
		case strings.HasPrefix(line, "-"):
			b.WriteString(line[1:] + "\n")
		case strings.HasPrefix(line, "+"):
			a.WriteString(line[1:] + "\n")
		case strings.HasPrefix(line, " "):
			b.WriteString(line[1:] + "\n")
			a.WriteString(line[1:] + "\n")
		}
	}
	return b.String(), a.String()
}

// LoadCorpus parses every check file, keyed by its path.
func LoadCorpus(paths []string) (map[string]Check, error) {
	corpus := make(map[string]Check, len(paths))
	for _, file := range paths {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		check, err := ParseChecks(filepath.Base(file), data)
		if err != nil {
			return nil, err
		}
		corpus[file] = check
	}
	return corpus, nil
}

// WriteSelection records which checks this run took.
func WriteSelection(root string, s Selection) (string, error) {
	if s.SelectedAt.IsZero() {
		s.SelectedAt = time.Now().UTC()
	}
	encoded, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encoding the selection: %w", err)
	}
	dir := filepath.Join(root, SelectionDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("making %s: %w", dir, err)
	}
	path := filepath.Join(dir, "latest.json")
	if err := os.WriteFile(path, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("writing the selection: %w", err)
	}
	return path, nil
}

// ReadSelection reads the record; false with no error when none was written.
func ReadSelection(root string) (Selection, bool, error) {
	path := filepath.Join(root, SelectionDir, "latest.json")
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return Selection{}, false, nil
	}
	if err != nil {
		return Selection{}, false, fmt.Errorf("reading %s: %w", path, err)
	}
	var s Selection
	if err := json.Unmarshal(data, &s); err != nil {
		return Selection{}, false, fmt.Errorf("reading %s: %w", path, err)
	}
	return s, true, nil
}
