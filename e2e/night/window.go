// Package night is the e2e night run: once a night, between 23:00 and 07:00,
// the full suite on the latest origin/main when it has moved since the last
// green night, an overnight fix of what went red on one branch for the night,
// and a result any session can read in the morning.
//
// The spec is docs/superpowers/specs/2026-10-27-e2e-night-run-design.md.
package night

import "time"

// The window the operator gave the night: the Mac is free from 23:00, and the
// screen must be theirs again at 07:00.
const (
	startHour = 23
	endHour   = 7
)

// InWindow says whether now is inside the night, local time.
func InWindow(now time.Time) bool {
	return now.Hour() >= startHour || now.Hour() < endHour
}

// Deadline is the next 07:00 after now: the moment the screen must be free.
func Deadline(now time.Time) time.Time {
	end := time.Date(now.Year(), now.Month(), now.Day(), endHour, 0, 0, 0, now.Location())
	if !now.Before(end) {
		end = end.AddDate(0, 0, 1)
	}
	return end
}

// NightOf is midnight of the date the night started: an hour before 07:00
// belongs to the night that began the evening before.
func NightOf(now time.Time) time.Time {
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if now.Hour() < endHour {
		day = day.AddDate(0, 0, -1)
	}
	return day
}
