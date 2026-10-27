package night

import (
	"fmt"
	"html"
	"time"
)

// Label is the launchd job's name.
const Label = "com.yehia-khalil.wakil.e2e-night"

// Plist is the launchd job: the night at 23:00, with the PATH the installer
// had (launchd's own has no go, make or claude), logging to logPath.
func Plist(binary, repo, logPath, path string) string {
	esc := html.EscapeString
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>run</string>
		<string>--repo</string>
		<string>%s</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>%d</integer>
		<key>Minute</key>
		<integer>0</integer>
	</dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>%s</string>
	</dict>
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>
</dict>
</plist>
`, Label, esc(binary), esc(repo), startHour, esc(path), esc(logPath), esc(logPath))
}

// LastNight is the most recent night that should have finished by now: the
// night before tonight's while tonight's is still running.
func LastNight(now time.Time) time.Time {
	if InWindow(now) {
		return NightOf(now).AddDate(0, 0, -1)
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	return today.AddDate(0, 0, -1)
}
