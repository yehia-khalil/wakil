package driver

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// RoomAFixtureNeeds is how much free space a launch is refused below.
//
// **Measured, not guessed.** A launch stages the whole `Wakil.app` into the
// fixture — 127 MiB on 2026-09-25 — and then runs an app that opens shells,
// writes a keychain, a journal, a layout and the evidence of any failure
// beside them. Two bundles' worth plus a quarter of a gigabyte of working room
// is the smallest number that is comfortably more than what was observed and
// still small enough to be a real signal on any machine anyone develops on.
const RoomAFixtureNeeds = 512 << 20

// FreeBytesOn reports the space available to this user on the filesystem
// holding path, walking up to the nearest directory that exists — the fixture
// root is usually about to be created.
func FreeBytesOn(path string) (uint64, error) {
	for dir := path; ; {
		var stat unix.Statfs_t
		if err := unix.Statfs(dir, &stat); err == nil {
			return stat.Bavail * uint64(stat.Bsize), nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return 0, fmt.Errorf("no existing directory at or above %s to measure", path)
		}
		dir = parent
	}
}

// RefuseIfDiskIsTight stops a launch that has nowhere to stage itself.
//
// **A full disk is not a broken app, and telling them apart is worth a
// precondition of its own** — the argument that produced RefuseIfScreenLocked,
// applied to the other environmental fault that was making these checks
// unrunnable.
//
// #284, measured 2026-09-24: twenty-odd consecutive green runs while the
// volume had room, then **6 of 6 failures once it was at 97%**, reproduced
// with the branch's app and harness stashed — so it was neither. The failure
// presents as the agent never having been spawned, which reads exactly like a
// defect in the window that was supposed to spawn it.
//
// **This is what lets the agent checks join `make e2e`.** They were held out
// because they "would make `make e2e` red for a reason that is not the
// branch's, which is how a gate gets switched off". A run that refuses up
// front and names the disk is not red for the branch's reason; it is not red
// at all until someone frees some space.
//
// An error reading the filesystem is the caller's to ignore, for
// RefuseIfScreenLocked's reason: a harness that would not run because it could
// not measure the disk would be strictly worse than one that tried.
func RefuseIfDiskIsTight(root string) error {
	if root == "" {
		root = os.TempDir()
	}
	free, err := FreeBytesOn(root)
	if err != nil {
		return nil
	}
	return roomRefusal(root, free)
}

func roomRefusal(root string, free uint64) error {
	if free >= RoomAFixtureNeeds {
		return nil
	}
	return fmt.Errorf(
		"%s has %s free and a fixture launch needs %s: it stages the whole bundle before it "+
			"starts, and a launch that runs out of room presents as an agent that was never "+
			"spawned — which reads exactly like a defect in the window that was meant to spawn "+
			"it (#284, after 6 of 6 failures at 97%% full and twenty green runs either side). "+
			"Free some space and run again",
		root, mebibytes(free), mebibytes(RoomAFixtureNeeds))
}

// mebibytes renders a byte count the way a person reading a refusal wants it.
func mebibytes(n uint64) string {
	return fmt.Sprintf("%d MiB", n>>20)
}
