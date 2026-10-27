package night

import (
	"testing"
	"time"
)

func at(day, hour, minute int) time.Time {
	return time.Date(2026, time.October, day, hour, minute, 0, 0, time.Local)
}

func TestTheWindowRunsFrom23To7(t *testing.T) {
	for _, now := range []time.Time{at(27, 23, 0), at(28, 2, 0), at(28, 6, 59)} {
		if !InWindow(now) {
			t.Errorf("%s should be inside the window", now)
		}
	}
	for _, now := range []time.Time{at(28, 7, 0), at(27, 22, 59), at(28, 12, 0)} {
		if InWindow(now) {
			t.Errorf("%s should be outside the window", now)
		}
	}
}

func TestTheDeadlineIsTheNext7(t *testing.T) {
	if got := Deadline(at(27, 23, 0)); !got.Equal(at(28, 7, 0)) {
		t.Errorf("Deadline(23:00) = %s", got)
	}
	if got := Deadline(at(28, 2, 0)); !got.Equal(at(28, 7, 0)) {
		t.Errorf("Deadline(02:00) = %s", got)
	}
}

func TestAnHourBefore7BelongsToTheNightBefore(t *testing.T) {
	if got := NightOf(at(28, 2, 0)); !got.Equal(at(27, 0, 0)) {
		t.Errorf("NightOf(02:00 Oct 28) = %s", got)
	}
	if got := NightOf(at(27, 23, 0)); !got.Equal(at(27, 0, 0)) {
		t.Errorf("NightOf(23:00 Oct 27) = %s", got)
	}
}
