package driver

import (
	"fmt"
	"os"
	"path/filepath"
)

// SpeechScriptEnv names the variable that swaps the app's microphone for a
// scripted speech engine (2d-ii, `SpeechRegistry.standard`). The app reads it
// once at launch; set, every hold of ⌥ plays the script instead of opening
// the microphone. Pinned against the Swift source by a test, for #301's
// reason: a mismatch would export a name nothing reads and fall back to the
// real microphone without a word.
const SpeechScriptEnv = "WAKIL_SPEECH_SCRIPT"

// SpeechScriptFile is where a fixture keeps the script, under its root.
const SpeechScriptFile = "speech-script.json"

// SpeechScript is what every fixture's microphone "hears" on every hold.
//
// **One script, carried by every launch, and it is a sentence a person might
// actually say.** Silence first, then words: the input device starts, nothing
// arrives for three seconds — long enough for the 1.5 s silence notice to be
// drawn and read — and then the words come in two partials, the second
// settling what the first left volatile. So one script serves every check:
// one that holds and waits for the notice reads it before the words arrive,
// and one that holds for the words reads them after.
//
// **The times are relative**, each `after` measured from the step before
// (`ScriptedSpeechProvider`'s player sleeps between steps). The words arrive
// 3.4 s into a hold; a seeded launch's assertions wait three seconds each, and
// a check reaches the words through the notice, so neither wait has to cover
// the whole hold.
//
// **No `final`.** On release the provider finalises with what its partials
// said, which is the contract a real engine keeps and the one the landing
// rule reads — a script that carried its own final would test a shortcut.
const SpeechScript = `[
  {"after": 0, "kind": "started", "device": "` + SpeechScriptDevice + `"},
  {"after": 3.0, "kind": "audio"},
  {"after": 0.1, "kind": "partial", "settled": "say hello", "volatile": "from the"},
  {"after": 0.3, "kind": "partial", "settled": "` + SpeechScriptWords + `", "volatile": ""}
]
`

// SpeechScriptDevice is the input device the script names, which the silence
// notice repeats: "Hearing nothing from E2E Microphone".
const SpeechScriptDevice = "E2E Microphone"

// SpeechScriptWords is what the script settles on, and so what lands in the
// composer when ⌥ is released.
const SpeechScriptWords = "say hello from the microphone"

// writeSpeechScript puts the script under the fixture's root.
func writeSpeechScript(root string) (string, error) {
	path := filepath.Join(root, SpeechScriptFile)
	if err := os.WriteFile(path, []byte(SpeechScript), 0o644); err != nil {
		return "", fmt.Errorf("fixture: writing the speech script: %w", err)
	}
	return path, nil
}
