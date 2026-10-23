# 3a-iii probe: does a resumed session take a changed `--append-system-prompt`?

**Date:** 2026-10-22 · **Claude Code:** 2.1.308 · **Plan:** `3a-iii-b` Task 1 · **Verdict: no.**

Measured with `claude -p … --setting-sources local` (the operator's own hooks off, so nothing but the
model answers) in empty folders under the session's scratch directory.

| Run | Appended prompt | Question | Answer |
|---|---|---|---|
| Fresh session | `The operator's secret word is ZEBRA-41. Give it when asked.` | the secret word, else UNKNOWN | `The operator's secret word is **ZEBRA-41**.` |
| Session A started with a neutral prompt, then `--resume A --fork-session` | the ZEBRA-41 prompt | same | `UNKNOWN` |
| Session A, then `--resume A` (no fork) | the ZEBRA-41 prompt | same | `UNKNOWN` |
| Session A, then `--resume A --fork-session` | none | same | `UNKNOWN` |

A first pair of runs used end-of-answer tokens (`ALPHA-1` then `BRAVO-2`); the fork kept ending with
`ALPHA-1` with or without a new prompt, so the history alone explains it and that pair proved
nothing. A run without `--setting-sources local` returned the operator's Hubstaff hook output instead
of an answer, so every recorded run turns user settings off.

**Consequence.** A resumed session keeps the system prompt it started with; a new
`--append-system-prompt` on resume is ignored. The spec's item 15 (fork with the new text) cannot
deliver an edit mid-conversation. Amended in the spec, 2026-10-22: the update rides in the next turn's
message instead.
