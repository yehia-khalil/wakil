package driver

import (
	"path/filepath"
	"strings"
	"testing"
)

// A disk with room is not mentioned at all: a precondition that spoke on every
// healthy run would be noise, and noise is what gets a gate switched off.
func TestADiskWithRoomIsNotMentioned(t *testing.T) {
	if err := roomRefusal("/tmp", RoomAFixtureNeeds); err != nil {
		t.Errorf("a disk with exactly enough room was refused: %v", err)
	}
	if err := roomRefusal("/tmp", 40<<30); err != nil {
		t.Errorf("a disk with forty gigabytes was refused: %v", err)
	}
}

// And one without says what to go and do, rather than letting the launch blame
// the app for an agent it had nowhere to write.
func TestATightDiskIsRefusedByName(t *testing.T) {
	err := roomRefusal("/private/tmp", 12<<20)
	if err == nil {
		t.Fatal("a disk with 12 MiB free was allowed to start a launch")
	}
	for _, want := range []string{"/private/tmp", "12 MiB", "512 MiB", "#284", "Free some space"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, err)
		}
	}
	// The sentence has to connect the disk to the symptom, or a reader who
	// has already seen "the agent was never run" will not believe it is this.
	if !strings.Contains(err.Error(), "never spawned") {
		t.Errorf("the refusal does not name the symptom it explains: %v", err)
	}
}

// The fixture root usually does not exist yet — `Session.Run` measures before
// `NewFixture` creates it — so the measurement has to walk up to something
// real rather than failing and being ignored.
func TestARootThatDoesNotExistYetIsStillMeasured(t *testing.T) {
	notYet := filepath.Join(t.TempDir(), "wakil-e2e-0", "home", "deeper")
	free, err := FreeBytesOn(notYet)
	if err != nil {
		t.Fatalf("a root that is about to be created could not be measured: %v", err)
	}
	if free == 0 {
		t.Error("the filesystem holding a temp directory reported no free space at all")
	}
}

// And the live path answers for the machine this is running on, so a wiring
// mistake between the two is caught here rather than by a gate that quietly
// never refuses.
func TestTheLivePreconditionMeasuresTheRealFilesystem(t *testing.T) {
	free, err := FreeBytesOn(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	refusal := RefuseIfDiskIsTight(t.TempDir())
	if free >= RoomAFixtureNeeds && refusal != nil {
		t.Errorf("%d MiB free and the launch was refused: %v", free>>20, refusal)
	}
	if free < RoomAFixtureNeeds && refusal == nil {
		t.Errorf("%d MiB free and the launch was allowed", free>>20)
	}
}
