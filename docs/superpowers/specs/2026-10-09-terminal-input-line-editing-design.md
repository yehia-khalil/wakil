# Terminal pane: paste, and editing a selection on the input line

**Date:** 2026-10-09
**Status:** design approved by the operator 2026-10-09, section by section; §1–§2 amended while
planning (offsets counted from the cursor)
**Issue:** #365 — *"Terminal pane: no paste, and a selection can't be deleted or replaced as a whole"*
**Scope:** a fix to the shipped terminal pane (2c-iii). Not a Phase 3 sub-phase; waits on nothing.

---

## Problem

Found on the 3a-i walk (2026-10-09): the runbook's steps 7 and 9 had to be typed by hand.

1. **⌘V does nothing.** `terminalKeyBytes` (`TerminalPaneSupport.swift`) returns `nil` for any
   ⌘ chord, and nothing else reads the pasteboard into the pty. The pane can copy a block out
   (`Copy`) but nothing pastes in.
2. **A selection on the input line can't be deleted or replaced.** Select typed text, press
   Backspace: one character goes. Select and type: the text is inserted at the shell's cursor.

**A correction to the issue.** It asks for this "as in Terminal.app and iTerm". Neither does
it: in both, a selection is a screen highlight and Backspace still deletes one character at the
shell's cursor. Only terminals that run their own input editor (Warp) replace a selection. The
operator wants that behaviour, on the input line only.

**Why the pane can't just read the selection.** The live region draws one `Text` per row with
`.textSelection(.enabled)` (`TerminalPane.swift`, `liveRegion()`). SwiftUI exposes no API to
read the selected range, so the pane has to track its own selection there.

## Decision: zsh keeps the line; the pane asks it to edit

Three shapes were weighed with the operator:

| | Shape | Verdict |
|---|---|---|
| A | Paste only, selection stays a highlight (Terminal.app) | Declined: the operator wants replace |
| B | The pane owns the line while you type, and hands it to zsh on Tab, ↑, ^R or a control key | Agreed first, then replaced by C |
| **C** | **zsh owns the line throughout; the pane asks zsh's line editor to replace a span** | **Chosen as "the most native"** |

C wins because nothing leaves the shell: completion, history, `^R`, zsh-syntax-highlighting
and zsh-autosuggestions keep working as you type, and select-and-replace works on every line,
before or after Tab. B lost select-and-replace on any line where Tab or ↑ had been pressed, and
hid the plugins until the hand-off.

**Invariant 2 is untouched.** Paste and the replace request are bytes to the pty through
`WindowModel.sendToTerminal`, the same path as a keystroke ("a keystroke is text-field editing,
not something Invariant 2 has an opinion about"). Nothing is submitted; `term_run` still fires
only on OSC 133 `C`.

## Behaviour

### Paste

- **⌘V at the prompt** types the clipboard at the cursor. If the shell has turned on bracketed
  paste (zsh does by default), the text is wrapped in `ESC[200~ … ESC[201~`, so a multi-line
  paste lands as one block and nothing runs until Enter.
- **⌘V with a selection on the input line** replaces the selection with the clipboard.
- **⌘V while a program runs** (python, ssh, `read`) sends the clipboard to it the same way,
  with no selection logic.
- An empty or non-text pasteboard does nothing.

### Selection on the input line

- **The live region** (the rows after `▸` where the prompt and typed text sit) gets the pane's
  own selection: drag, double-click a word, ⇧← / ⇧→. The pane draws the highlight, the same
  way it draws `CursorMark`.
- With a selection active:

  | Key | Effect |
  |---|---|
  | A printable character | Replaces the selection with it |
  | Backspace, Delete | Removes the selection |
  | ⌘V | Replaces the selection with the clipboard |
  | ⌘C | Copies the selection |
  | ←, →, Tab, ↑, ↓, a control key, a click | Clears the selection; the key reaches zsh as today |

- Afterwards the cursor sits at the end of the edit. Nothing jumps (rule 6) and nothing asks
  for confirmation (rule 1).

### Where it does not apply

- **Output above the prompt** keeps SwiftUI's read-only selection: copy only.
- **Selection editing is off** while a command runs, in a full-screen program (alternate
  screen), and in any shell that has not reported support (macOS's `/bin/bash` 3.2). Paste
  works in all of these.
- **A selection that runs into zsh's grey suggestion text, or past the end of the line**, edits
  only the part inside the real line (zsh clamps to `${#BUFFER}`; the suggestion is
  `POSTDISPLAY`, not `BUFFER`).

### Interaction rules

Rule 1 (no confirmation: an edit destroys nothing the operator can't retype); rule 6 (the cursor
stays at the edit); rule 7 (a request zsh can't match is ignored, not refused with an error).
No Enter-to-commit, no jump.

## Design

Four units. Every one with logic lives in `WakilKit`, where it can be tested.

### 1. The edit command in the shell (`ShellIntegration.swift`)

The generated rc gains a zle widget, `__wakil_replace`, bound (in every keymap zsh uses for
editing: `main`, `viins`, `vicmd`, `emacs`) to a private sequence, `ESC [ 9 9 9 ~` followed by a
payload ending in `BEL`:

```
ESC[999~ <startDelta>;<endDelta>;<base64 expected>;<base64 replacement> BEL
```

`startDelta` and `endDelta` are signed character offsets **relative to zsh's `CURSOR`**, `end`
exclusive (see §2 for why relative). The widget reads the payload with `read -k` up to `BEL`,
then:

1. computes `start = CURSOR + startDelta`, `end = CURSOR + endDelta`;
2. if `start < 0` (the selection began in the prompt), drops that many leading characters from
   the expected text and sets `start = 0`; clamps `end` to `${#BUFFER}`; if `start >= end`,
   ignores the request;
3. trims the expected text to `end - start` characters and compares it with
   `${BUFFER:start:end-start}`; on a mismatch, ignores;
4. sets `BUFFER` to the prefix, the replacement and the suffix, and `CURSOR` to
   `start + ${#replacement}`; then `zle -R`.

base64 keeps `;`, newlines and `BEL` in operator text from ending the payload early, the same
reason OSC 133 `C` carries `wakil_cmd` as base64.

**bash 4 and later** get the same command through `bind -x` on the same sequence, reading the
payload with `read -r -d $'\a'` and editing `READLINE_LINE` / `READLINE_POINT`. bash 3.2 has
neither variable and gets no binding.

**The support signal.** After installing the binding, the rc emits `OSC 1337;WakilEdit=1 BEL`
once per prompt, from the same `precmd` / `PROMPT_COMMAND` hook that emits the `A` mark.
`TerminalMarkScanner` recognises it as a new mark, `.editSupported`. The pane enables selection
editing only after seeing it; a shell without it (bash 3.2, an rc that failed to load) never
gets the feature and never receives the private sequence.

### 2. Selection to line offsets (pure, `WakilKit/Terminal`)

**Counted from the cursor, not from the `B` mark** (amended while planning, 2026-10-09).
`TerminalSession.consume` feeds a whole chunk to SwiftTerm *before* it reads the chunk's marks,
so the cursor position read at `B` is the position after the whole chunk, not at the mark. The
cursor, though, is something both sides know exactly: the screen cursor sits on `BUFFER[CURSOR]`.
So the pane counts cells from the cursor and zsh adds its own `CURSOR`.

`TerminalSession.inputLine()` publishes the cursor's run of rows (the cursor row plus the rows
SwiftTerm marks `isWrapped` above and below it) as cells in reading order, each a character, its
width and its screen point; the trailing half of a wide character is skipped. It answers `nil`
unless the session is at a prompt (`B` seen, no `A` or `C` since), `.editSupported` arrived
after the latest `A`, and the alternate screen is off.

```swift
public func terminalLineEdit(selection: TerminalGridRange, line: TerminalInputLine) -> TerminalLineEdit?
```

returns the selected cells' indices relative to the cursor's index, plus the text they cover, or
`nil` when no cell is selected. Prompt text and blank cells past the end of the line may be
included; zsh trims them (§1). A wrong mapping can't damage the line: zsh's expected-text check
rejects it.

### 3. What a key does (`terminalPaneKeyClaim`, `TerminalPaneSupport.swift`)

The claim gains two outcomes beside `.forwardToPty`:

- `.paste`, for ⌘V, in every mode;
- `.replaceSelection(String)`, for a printable character (the character), Backspace or Delete
  (the empty string), when a selection is active and editing is enabled.

Two pure helpers build the bytes:

- `terminalPasteBytes(_ text: String, bracketed: Bool) -> [UInt8]` turns `\r\n` and `\n` into
  `\r`, **strips any `ESC[201~` and `ESC[999~` from the text**, so pasted text can't end the
  paste early or forge an edit request, and wraps the result in `ESC[200~ … ESC[201~` when
  `bracketed`. `bracketed` is SwiftTerm's own `Terminal.bracketedPasteMode`, which it already
  tracks from DECSET 2004.
- `terminalReplaceBytes(edit: TerminalLineEdit, replacement: String) -> [UInt8]` builds the payload in §1.

### 4. The pane (`TerminalPane.swift`)

- `liveRegion()` drops `.textSelection(.enabled)` and takes a drag gesture, a double-click and
  ⇧← / ⇧→. Cells are monospaced (12 pt, 15 pt rows), so a point maps to a cell by division, the
  same arithmetic `reportSize` already uses. The highlight is one overlay per row, like
  `CursorMark`, never a view per cell (`LiveGrid`'s own measurement rules that out).
- Editing is enabled when the snapshot carries an `inputLine` (§2 lists the conditions).
- `.paste` reads `NSPasteboard.general`; with a selection and editing enabled it sends a replace,
  otherwise `terminalPasteBytes`. ⌘C with a pane selection copies it.
- Any byte sent to the pty clears the selection. So does new output that moves the live region.

## Testing

**Unit (`WakilKitTests`), no GUI and no shell:**

- `terminalPasteBytes`: bracketed and not; line-ending conversion; a planted `ESC[201~` and a
  planted `ESC[999~` are stripped.
- `terminalLineEdit`: a plain line; a line wrapped across rows; wide characters (CJK); a
  selection before and after the cursor; one covering prompt text; one selecting no cell (`nil`).
- `terminalPaneKeyClaim`: typing, Backspace and ⌘V with and without a selection; editing off with
  no prompt, in the alternate screen, and without `.editSupported`.
- `TerminalMarkScanner`: recognises `OSC 1337;WakilEdit=1`.

**Real shell, no GUI** (zsh, plus Homebrew bash when installed), through `PseudoTerminal` with the
generated rc:

- type `echo git checkout main`, send a replace of `checkout` → `switch`, press Enter, expect the
  output `git switch main`;
- the same with the wrong expected text: output `git checkout main`, unchanged;
- a bracketed paste of two lines does not run before Enter;
- the rc emits `WakilEdit=1` under zsh and bash 4+, and never under `/bin/bash` 3.2.

**Cover rung (the e2e auditor; needs the shared screen, so the operator and peer sessions are
asked first):** ⌘V at the prompt; a multi-line paste that doesn't run; select-and-type;
select-and-Backspace; a selection over output stays copy-only.

## Out of scope

- Selection editing inside running programs, REPLs, ssh sessions or full-screen programs.
- fish and other shells (the rc supports zsh and bash only).
- A pane-drawn selection over output rows (they keep SwiftUI's).
- Undo beyond what zsh already offers (`undo` widget, `^_`).

## Follow-ups

- When #365 closes, correct its "as in Terminal.app and iTerm" line in the closing comment
  (drafted to the operator first).
