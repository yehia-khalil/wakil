package driver

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// PanePath reads one value out of a pane snapshot, by a dotted path with
// optional list indexes: `shell`, `blocks[-1].exitCode`, `blocks[0].output`.
//
// **It exists because a terminal pane's facts are not top-level.** #251's
// `expect.pane` read one key of the snapshot and compared it as a scalar,
// which is everything a data surface's `rowCount` needs and nothing a
// terminal's needs: *a block carrying its exit code and duration* is
// `blocks[-1].exitCode` and `blocks[-1].durationMs`, two levels down and
// behind an index.
//
// **`[-1]` is the index every terminal check actually wants.** A check
// asserts about the command it just ran; a positive index would have to be
// counted by hand and would change the moment a step was inserted above it.
//
// Every failure names what WAS there — the keys of the object, the length of
// the list — because the alternative is a second live run to find out, and a
// live run costs a launch and the operator's screen.
func PanePath(fields map[string]interface{}, path string) (interface{}, error) {
	var current interface{} = fields
	for _, segment := range strings.Split(path, ".") {
		name, indexes, err := parseSegment(segment)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if name != "" {
			object, isObject := current.(map[string]interface{})
			if !isObject {
				return nil, fmt.Errorf("%s: %q is not an object, so it has no key %q",
					path, segment, name)
			}
			value, carried := object[name]
			if !carried {
				return nil, fmt.Errorf("%s: there is no %q here (what is here: %s)",
					path, name, joinCommas(sortedKeys(object)))
			}
			current = value
		}
		for _, index := range indexes {
			list, isList := current.([]interface{})
			if !isList {
				return nil, fmt.Errorf("%s: %q is not a list, so it cannot be indexed", path, name)
			}
			resolved := index
			if resolved < 0 {
				resolved = len(list) + resolved
			}
			if len(list) == 0 {
				return nil, fmt.Errorf(
					"%s: %q is empty, so there is no element %d — the usual cause is that the "+
						"command never ran, or has not finished", path, name, index)
			}
			if resolved < 0 || resolved >= len(list) {
				return nil, fmt.Errorf("%s: %q holds %d element(s), so there is no element %d",
					path, name, len(list), index)
			}
			current = list[resolved]
		}
	}
	return current, nil
}

// segmentPattern splits `blocks[-1]` into a name and its indexes.
var segmentPattern = regexp.MustCompile(`^([^\[\]]*)((\[-?\d+\])*)$`)

var indexPattern = regexp.MustCompile(`\[(-?\d+)\]`)

func parseSegment(segment string) (name string, indexes []int, err error) {
	match := segmentPattern.FindStringSubmatch(segment)
	if match == nil {
		return "", nil, fmt.Errorf("%q is not a readable path segment", segment)
	}
	name = match[1]
	for _, index := range indexPattern.FindAllStringSubmatch(match[2], -1) {
		value, convErr := strconv.Atoi(index[1])
		if convErr != nil {
			return "", nil, fmt.Errorf("%q carries an index that is not a number", segment)
		}
		indexes = append(indexes, value)
	}
	if name == "" && len(indexes) == 0 {
		return "", nil, fmt.Errorf("an empty path segment names nothing")
	}
	return name, indexes, nil
}

// ValidPanePath refuses a path whose GRAMMAR is broken — `blocks[1`,
// `a..b`, `blocks[x]`, an empty segment.
//
// **It does not catch a misspelled key, and an earlier version of this
// comment claimed it did.** `blcoks[-1].exitCode` parses perfectly: a typo is
// grammatically a good name, and nothing without the live snapshot can say
// otherwise. What that leaves is handled where it can be — `present: false`
// requires its CONTAINER to resolve (see PanePathContainer), which is the
// rule that actually closes the vacuous case.
//
// Checked at parse time because it is knowable without a window, and a
// malformed path discovered against a live instance costs a launch.
func ValidPanePath(path string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("an empty path names nothing")
	}
	for _, segment := range strings.Split(path, ".") {
		if _, _, err := parseSegment(segment); err != nil {
			return err
		}
	}
	return nil
}

// PanePathContainer splits a path into the container that must exist and the
// leaf whose presence is in question — `blocks[-1].exitCode` becomes
// `blocks[-1]` and `exitCode`. A single-segment path has no container, and
// its container is the snapshot itself.
//
// **It exists so `present: false` cannot be satisfied by a typo.** That
// predicate is satisfied by any path that fails to resolve, and a misspelled
// key fails to resolve — so `blcoks[-1].exitCode` passed against every build,
// having looked at nothing. Grammar checking narrowed the hole and could
// never close it: a typo is grammatically a perfectly good name. Requiring
// the CONTAINER to resolve is what closes it, because the container is the
// part a check author cannot get wrong without saying something false about
// the shape of the snapshot.
func PanePathContainer(path string) (container, leaf string) {
	index := strings.LastIndex(path, ".")
	if index < 0 {
		return "", path
	}
	return path[:index], path[index+1:]
}
