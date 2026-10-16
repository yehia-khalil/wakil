# Which STT engine hears Wakil's vocabulary — a pre-registered probe

**Status: RUN 2026-09-16. Result in §6. Open question 10 closed the same day — Apple ships
as the default, Whisper stays selectable.**

**§1 to §5 were written before any audio existed, and §3, §4 and §5 have not been edited
since.** Every other `*-probe.md` here was written after its measurement; this one was
written before, because its value depends entirely on §5's win condition having been fixed
in advance. §6 onwards was added after the run. The one correction to the pre-registered
half is §6's erratum — §3 says "thirty identifier tokens" and contains twenty-nine — which
is recorded rather than fixed in place, for the same reason.

**Machine:** macOS 26.6.2 · **Blocks:** open question 10, and therefore the shape of 2d

---

## 1. What prompted it

Decision 18 ordered the engines: *"Apple's on-device recognition is the default — free,
private, no model download. Local Whisper is the accuracy upgrade."* That was written on
2026-09-03 against `SFSpeechRecognizer` and was true of it.

macOS 26 replaced that API. `SpeechAnalyzer`/`SpeechTranscriber` beats Whisper
large-v3-turbo on English word error rate at roughly twice the speed, on device —
9.02% → 2.12% on clean speech, 16.25% → 4.56% on noisy. **The general ordering is
reversed.**

**But `SpeechAnalyzer` was reported to have dropped custom vocabulary**, which
`SFSpeechRecognizer` had, and which Whisper approximates through prompt conditioning.
*(2026-09-16, after the run: **that report is wrong about the API and right about the
outcome**. `AnalysisContext.contextualStrings` exists in the macOS 27.0 SDK and
`SpeechAnalyzer.setContext(_:)` attaches it — but see §6.1: set with §3's 29 identifiers
and read back intact, it changes the transcript by not one character.)* Wakil does not dictate prose. It
hears `writeRef`, `wakilcore`, `2c-ii-b`, `AssertSQLMutation`, `INI-2835`. **The axis
Wakil is on is the one axis where the reversal does not obviously apply**, and nobody
has measured it.

Decision 1 — native macOS app over a VS Code extension — reverses if voice gets cut.
This probe is the cheapest thing that moves that.

## 2. The two candidates, and why these builds

| | Build | Why this one |
|---|---|---|
| **Apple** | `SpeechAnalyzer` + `SpeechTranscriber`, macOS 26 | The only on-device Apple engine that is current. `SFSpeechRecognizer` is not a candidate — it has custom vocabulary but four times the word error rate |
| **Whisper** | **WhisperKit** (Argmax), `large-v3-turbo`, with `initial_prompt` carrying Wakil's identifier list | Swift, Core ML, macOS 13+ |

**Why not `openai/whisper`, the Python reference implementation.** It is cheaper to set
up and would have been adequate if Apple won. It was rejected on the operator's
instruction (2026-09-16): probe the kit that would actually ship. Quantized Core ML
weights and full-precision PyTorch weights do not score identically, so probing one and
shipping the other measures an artefact that never ships. The cost of that discipline is
a day of WhisperKit setup; the cost of skipping it is a result that has to be re-run.

**Why WhisperKit and not `whisper.cpp`.** The Go capability layer is built
`CGO_ENABLED=0` by deliberate policy — see the Makefile's rationale and
`wakilcore.SecretSet`, which is written against that premise. A `whisper.cpp` cgo binding
cannot live there without reopening that trade-off. WhisperKit is Swift and lives in the
app, beside `SpeechAnalyzer`, behind one protocol in `WakilKit`. It would be
`WakilKit`'s first external dependency; the package has none today.

**Both candidates are on-device.** The cloud tier is not in this probe, so Decision 18's
data-policy argument does not arise for either.

## 3. The utterance set

**Twenty-five utterances, recorded once by the operator, replayed to both engines from
the same audio files.** One recording, two engines — not two recording sessions, which
would confound engine accuracy with how clearly you happened to speak that day.

Speak them as commands to Wakil, at a normal working pace, in a normal working room. Do
not enunciate for the microphone; the point is what Wakil will actually receive.

| # | Utterance | Identifiers scored |
|---|---|---|
| 1 | "Open the DB pane on staging core" | `staging`, `core` |
| 2 | "Show me `edit_quote` on the core database" | `edit_quote` |
| 3 | "What's the `writeRef` on this database?" | `writeRef` |
| 4 | "Does `wakilcore` export `AssertSQLMutation`?" | `wakilcore`, `AssertSQLMutation` |
| 5 | "Move INI-2835 to review" | `INI-2835` |
| 6 | "Read the acceptance runbook for 2c-ii-b" | `2c-ii-b` |
| 7 | "What did 2b-viii's walk find?" | `2b-viii` |
| 8 | "Switch the org to Umbrella" | `Umbrella` |
| 9 | "Set `transaction_read_only` to one" | `transaction_read_only` |
| 10 | "Grep for `hardenMySQLWriteConfig`" | `hardenMySQLWriteConfig` |
| 11 | "Open `WakilWindow.swift`" | `WakilWindow.swift` |
| 12 | "Run `make app-test`" | `make app-test` |
| 13 | "What's in `phase-2c-ii-acceptance.md`?" | `phase-2c-ii-acceptance.md` |
| 14 | "Show the `JSONValue` integer case" | `JSONValue` |
| 15 | "Which provider is `wakil-pm` running under?" | `wakil-pm` |
| 16 | "Start a session on the `wakil-acceptance-2` project" | `wakil-acceptance-2` |
| 17 | "Delete from `edit_bit` where id equals three" | `edit_bit` |
| 18 | "Is `ctx_adopt_provider` operator-only?" | `ctx_adopt_provider` |
| 19 | "Check `Invariant 6` in the charter" | `Invariant 6` |
| 20 | "What's the `writeGate` doing on production?" | `writeGate`, `production` |
| 21 | "Open `paths.go` in `internal/wakilcore`" | `paths.go`, `internal/wakilcore` |
| 22 | "Show me `acc-staging-core-write`" | `acc-staging-core-write` |
| 23 | "Does `describeEditability` return early?" | `describeEditability` |
| 24 | "List the databases on `wakilacc`" | `wakilacc` |
| 25 | "Re-run the query on the `events` pane" | `events` |

**Twenty-nine identifier tokens across twenty-five utterances** *(this line said "thirty" until 2026-09-16; see §6's erratum — the count was wrong, the set was not)*. The set is drawn from this
repository's own vocabulary rather than invented, and deliberately mixes the four shapes
Wakil's language actually takes: snake and camel case (`edit_quote`, `writeRef`),
hyphenated sub-phase labels that sound like dictation commands (`2c-ii-b`, `2b-viii`),
file paths and extensions (`WakilWindow.swift`, `internal/wakilcore`), and an external
key format (`INI-2835`).

## 4. Scoring

**Per identifier, exact match, case-sensitive.** A transcript that gets every word right
but one is a failed command — Wakil would dispatch the wrong action or none — so
sentence-level WER is the wrong instrument and is not recorded.

Normalise only these, before comparing:
- Leading and trailing whitespace.
- A transcript that spells an identifier correctly but splits it (`edit quote` for
  `edit_quote`, `two c two b` for `2c-ii-b`) **counts as a miss.** It is not what the
  action registry will match on.
- Surrounding punctuation the engine added.

Record for each engine: **identifiers exactly right, out of 30.** Record per-utterance
transcripts verbatim in §6 so the failures can be read, not just counted.

Also record, but do not score on: wall-clock latency from end-of-speech to final
transcript, and model download size. These decide nothing here; they are what §5's tie
falls back to.

## 5. The win condition — fixed before recording

> **Apple ships as the default unless WhisperKit gets at least 20% more identifiers
> exactly right** — that is, at least 6 more out of 30.

Agreed with the operator 2026-09-16, before any audio existed.

**Why the threshold is asymmetric in Apple's favour, stated plainly so the bias is
visible rather than hidden:** Apple costs nothing — no model download, no first external
dependency in `WakilKit`, no Core ML warm-up, and it is already ahead on general English.
WhisperKit has to pay for itself, and a margin inside the noise of a 30-token sample is
not payment. A 20% margin is roughly what a 30-token sample can distinguish from chance.

**If Whisper wins:** it becomes the default, Apple stays selectable, and
`if #available(macOS 26, *)` gating is what lets a pre-26 machine have an engine at all.

**If Apple wins:** 2d loses a model download, a Core ML dependency and a build-form
decision. Whisper stays in Decision 18 as the selectable upgrade — it does not get
deleted on one probe.

**Either way Decision 18 needs no amendment.** Pluggable per organisation stands; only
the default moves. Open question 10 closes on this result and on nothing else.

## 6. Result — 2026-09-16

**Both engines fail this vocabulary almost completely, and that is the result. Which one
wins is the smaller half of it.**

| | Exact (§4) | After normalisation |
|---|---|---|
| **Apple** `SpeechAnalyzer` | **4 / 29** | 14 / 29 |
| **WhisperKit** large-v3-turbo | **3 / 29** | 15 / 29 |

Scored by `scripts/probe/stt-score.py` against §4's rules rather than by eye, and checked by
hand against the same transcripts. Apple returned every utterance in 0.07–0.48s;
WhisperKit took 5.8–7.2s, inflated by §7.1's fresh-pipeline-per-file workaround.

**Erratum, recorded rather than corrected silently: §3 says "thirty identifier tokens"
and the table contains twenty-nine.** An arithmetic error in a document that forbids
editing itself after recording begins. It changes nothing: §5's threshold is an absolute
count ("at least 6 more"), and 20% of 29 rounds to 6 as well.

### 6.1 Both engines' vocabulary-biasing APIs are inert, and that is a symmetric finding

**Apple.** `AnalysisContext.contextualStrings[.general]` set to §3's 29 identifiers,
attached with `SpeechAnalyzer.setContext(_:)` before `analyzeSequence`, and **read back
from `analyzer.context` as 29 strings** — so the setter took. Re-running all 25 files
produced a transcript **byte-identical** to the run with no context at all.

**WhisperKit.** `DecodingOptions.promptTokens`, 163 tokens, under the 223 budget, with
`usePrefillPrompt` true. Byte-identical output with no prompt, with a prompt that is the
literal correct answer, and with a nonsense control (§7.2).

**Two vendors, two documented APIs, both accepted, neither doing anything measurable on
this vocabulary.** That is worth more than either engine's score, and it has one
consequence that rescues §6's comparison: **the two columns are fair.** Neither engine
was measured with its biasing working, so the 4-vs-3 is like for like. §7.2 worried the
result was unusable because only Whisper was handicapped; it turns out both were.

**It does not mean the APIs are broken** — only that they did nothing here, on this path,
for identifiers of this shape. Neither was pursued further, because §6.2 found something
that works for both engines at once and needs no vendor cooperation at all.

### Applying §5

WhisperKit is **behind by 1** on exact match and **ahead by 1** after normalisation. §5
required it to be ahead by 6. **By the condition as written, Apple ships as the default.**

**But §5 does not get to close open question 10 here, for the reason §7.2 gives.** The
WhisperKit column was produced with prompt conditioning inert — a nonsense control prompt
and the literal correct answer both changed nothing. Conditioning is designed to fix
exactly the misses Whisper has: `Wakil DM` for `wakil-pm`, `added bit` for `edit_bit`,
`a SQL mutation` for `AssertSQLMutation`. It would have to deliver six of them to change
the verdict, which is a large ask and not an impossible one. **q10 stays open on the
engine question.**

### 6.2 What the probe found that neither §1 nor §5 anticipated

**Ten of Apple's fifteen misses and twelve of WhisperKit's fourteen are the right words,
joined or cased wrongly.**

| Spoken | Apple heard | WhisperKit heard |
|---|---|---|
| `transaction_read_only` | "transaction read only" | "transaction read only" |
| `describeEditability` | "describe editability" | "describe editability" |
| `ctx_adopt_provider` | "CTX adopt provider" | "CTX adopt provider" |
| `hardenMySQLWriteConfig` | "harden my SQL, right Config" | **"harden MySQL write config"** |
| `JSONValue` | "Jason Value" | **"JSON value"** |
| `Invariant 6` | "invariant 6" | "invariant 6" |

**Neither engine is failing to hear the words. Both are failing to know that the words
are one token.** That is not an accuracy problem and a better engine does not fix it —
`SpeechAnalyzer` and Whisper make the *same* mistake on the *same* identifiers.

**And Wakil is the one participant that already knows the answer.** It holds the action
registry, the active project's table and column names, the loaded pane's contents and the
Jira scope's issue keys. A deterministic normalisation pass — fold case, spaces, hyphens,
underscores and apostrophes, then match against the identifiers currently in scope —
takes Apple from 4 to 14 and WhisperKit from 3 to 15 with no model change at all.

**Decision 11 already said this, in 2026-09-03, and nobody had measured it until now:**

> Mistranscribed identifiers (`RAF-142` → "raff one forty two") are resolved by the agent
> against real ticket and endpoint lists rather than by demanding clean audio — which is
> why STT accuracy is a preference, not a correctness requirement.

So this is not a new decision. It is an existing one, written as an assumption, now
carrying a number: **the resolver has to recover about two thirds of what the engine
returns**, and a deterministic fold does all of that without fuzzy matching. Decision 10
is the other half — *voice is a transport, not a command language* — and the transport
turns out to be adequate. What was missing was never a better engine; it was the layer
Decision 11 assumed and no phase has built, resolving against state Invariant 3 already
guarantees is readable.

**What it does not solve.** The fourteen remaining misses are genuinely wrong words, not
wrongly-joined ones: `writeRef` → "right ref", `Umbrella` → "together and", `INI-2835` →
"TL to 835", `2c-ii-b` → "2 C 2 B", `acc-staging-core-write` → "account staging code,
right". Normalisation cannot recover these; fuzzy matching against in-scope identifiers
might recover some, and that is a measurement nobody has made. **Roman numerals and
hyphenated version labels are the worst category in the set** and no engine or normaliser
will fix `2b-viii` → "2B8" — which is worth knowing before 2d's design assumes sub-phase
labels are speakable at all.


## 7. The harness

`scripts/probe/sttspike` — **kept, unlike every other spike this project has built.** The
convention is throwaway in `/tmp`, and it was built there on 2026-09-16 before recording;
it was moved into the repository afterwards because it produced a result the charter now
rests on, and `2d-i` will want to re-run it against the resolver. A spike in `/tmp` would
have made §6 unreproducible the moment the directory was cleaned.

```
cd scripts/probe/sttspike && swift build -c release
./.build/release/sttspike <dir-of-audio> [apple|whisper]     # default: both
```

It reads every `.wav`/`.m4a`/`.caf`/`.aiff` in the directory and prints one
tab-separated line per (engine, file): filename, wall-clock, transcript. **It does not
score.** §4's rules need a human reading the transcript — a split identifier counts as a
miss, and a string comparison would silently forgive it.

**Both engines read the same files**, which is the whole reason it is one tool rather
than two.

**Three things it cost to get right, recorded so the next person does not pay them
again:**

- **The model name.** WhisperKit's Core ML repo calls OpenAI's large-v3-turbo
  `openai_whisper-large-v3-v20240930`, after its release date. `large-v3-turbo` does not
  resolve at all, and `openai_whisper-large-v3_turbo` is a **different model** — plain
  large-v3 with a turbo compute-unit configuration. The error message for the first does
  not hint at the second.
- **Prompt conditioning** is `DecodingOptions.promptTokens`, not a string field. The
  vocabulary has to be tokenized and the special tokens filtered out, exactly as
  WhisperKit's own CLI does it. This is the only reason Whisper is a candidate at all —
  getting it silently wrong would have measured an unconditioned Whisper and scored it
  against Apple unfairly.
- **Apple's model is downloaded on first use**, via `AssetInventory`, not bundled. The
  harness installs it explicitly; without that a missing locale scores Apple at zero for
  a reason that has nothing to do with accuracy.

### Two defects found in WhisperKit 0.18.0 — one fixed, one blocking

**Both were found by the smoke test below, and neither raised an error.** Each would have
silently produced a number.

**1. Only the first file transcribes when `promptTokens` is set. FIXED.** With one
`WhisperKit` instance reused across files, file 1 returns a transcript and **every file
after it returns an empty string**. Reproduced on two independent sets of audio, 3 files
and 4 files, same pattern both times. `TextDecoder.swift` carries its own note that
prefill *"breaks if it starts at non-zero index"*, which is where the prompt shifts it.
The harness now builds a fresh pipeline per file — about 6 seconds each instead of 1, so
roughly 2½ minutes for §3's 25 files, which is a price worth paying. **Left unfixed this
would have scored Whisper 1 out of 25 and looked like a catastrophic accuracy result.**

**2. `promptTokens` appears to have no effect at all. NOT FIXED — this blocks the
probe.** Measured on one file, three conditions:

| Prompt | Transcript |
|---|---|
| none | `grep for hard and miscal write config` |
| `hardenMySQLWriteConfig` — the exact answer | `grep for hard and miscal write config` |
| `banana banana banana banana banana banana` — nonsense control | `grep for hard and miscal write config` |

**Byte-identical in all three.** A prompt that is the literal correct answer changes
nothing, and a nonsense prompt changes nothing either — so the tokens are not reaching
the decoder in any form that matters. `usePrefillPrompt` is `true`, which is the
condition WhisperKit requires for prompt tokens to be applied at all, and the tokens
encode (163 of them for §3's vocabulary, under the 223-token budget).

**Why this stops the probe rather than merely annoying it.** §1's whole argument is that
Apple wins on general English and Whisper's *only* remaining claim is custom vocabulary,
which Whisper has solely through prompt conditioning. A probe run in this state measures
an **unconditioned** Whisper and calls it Whisper. If Apple then wins, the result is
worthless — it is the trap the three notes above this section were written to avoid,
arriving by a different door. **See §6; this must be resolved before any audio is
scored.**

### A smoke test, which is not a result

The harness was exercised on **three synthetic utterances** generated with `say`, to
prove it runs end to end. Apple's engine returned, in 0.1–0.65s:

| Spoken | Heard | Identifiers |
|---|---|---|
| "What's the `writeRef` on this database?" | *"What's the right ref on this database?"* | `writeRef` → miss |
| "Read the acceptance runbook for `2c-ii-b`" | *"Read the acceptance run book for 2C2B."* | `2c-ii-b` → miss |
| "Does `wakilcore` export `AssertSQLMutation`?" | *"Does Raphicore export assert SQL mutation?"* | both miss |

**This is not §6 and must not be read as it.** It is `say`'s synthetic voice, not the
operator's; it is 3 utterances against §3's 25 and 4 identifiers against 30; and Whisper
was not run on the same audio. What it establishes is that the harness works and that the
question §1 asks is a real one — every identifier in the smoke test came back wrong, and
plausibly wrong, in the way that dispatches no action. It does **not** establish that
Apple loses, because nothing has yet been compared to anything.

## 8. How to run it — the operator's steps

Six steps. Everything except step 2 is a command; step 2 is the microphone and is the
only part no script can do.

### Step 0 — build (once)

```bash
cd scripts/probe/sttspike && swift build -c release
```

**Expect:** `Build complete!`. On a cold build WhisperKit's dependency graph takes a few
minutes.

### Step 1 — pre-flight the models

```bash
./.build/release/sttspike /tmp/sttaudio whisper
```

**Expect:** a ~950 MB download into `~/Documents/huggingface`, then Core ML compiles the
model for the Neural Engine on first load. **This takes several minutes and looks
hung — it prints nothing while it works.** Do this *before* recording, not after; there
is no reason for it to happen while you are sitting in a quiet room.

Done when three transcript lines appear. `/tmp/sttaudio` holds the synthetic smoke-test
files from §7; if they are gone, regenerate:

```bash
mkdir -p /tmp/sttaudio
say -o /tmp/sttaudio/01.aiff "What's the writeRef on this database?"
```

### Step 2 — record the 25 utterances *(your hands)*

```bash
./.build/release/sttspike record /tmp/sttprobe
```

**Expect:** the 25 utterances one at a time. Enter to start, speak, Enter to stop. `r`
re-records the previous one, `q` stops early and keeps what is written. Files land as
`01.wav` … `25.wav`, 16 kHz mono, matching §3's numbering — **the numbering is what makes
the transcripts scoreable against §3's third column**, so do not rename them.

**The first run will ask for microphone permission**, attributed to your terminal app. If
it fails instead of asking, grant it in System Settings → Privacy & Security →
Microphone and re-run.

**Speak them as commands to Wakil**, at a working pace, in a normal room. Do not
enunciate for the microphone. A probe run in an unnaturally clear voice measures an
engine you will never use.

```bash
ls /tmp/sttprobe        # expect 01.wav … 25.wav
```

### Step 3 — run both engines

```bash
./.build/release/sttspike /tmp/sttprobe 2>&1 | tee /tmp/sttprobe-results.txt
```

**Expect:** two blocks, `## Apple` then `## WhisperKit`, each 25 tab-separated lines of
`filename ⇥ seconds ⇥ transcript`. Apple's lines return in well under a second each;
WhisperKit's take longer and its first line takes longest of all.

**Both engines read the same files.** That is the point of one command rather than two,
and it is why step 2 must not be repeated between the two blocks.

### Step 4 — score, by hand, against §3 and §4

For each utterance, compare the transcript to §3's **Identifiers scored** column, and
count each identifier as right only if it appears **exactly** — `writeRef`, not "write
ref", not "right ref". A correctly spelled but split identifier is a **miss** (§4): the
action registry will not match it.

Two numbers come out, each **out of 30**. Nothing else is scored.

### Step 5 — write §6, then close open question 10

Paste both transcript blocks into §6 verbatim, with the two counts and the date. Then
apply §5's condition as written — **Apple ships unless WhisperKit is ahead by 6 or more**
— and:

- Close open question 10 in `open-questions.md` with the result and the two counts.
- Update the charter's §7 row for q10 to `closed <date>`, and its count line ("5 open,
  1 half open, 9 closed"). **Check `wc -w docs/wakil/north-star.md` after** — it was at
  4,095 against its own 4,000-word limit on 2026-09-16, so anything beyond the row itself
  belongs in a log.
- Add the dated result to Decision 18 beneath its 2026-09-16 note.

**Do not edit §3, §4 or §5 while doing any of this.** If the result feels wrong, that is
the feeling the pre-registration exists to overrule — record it, then argue with it in a
separate dated entry that a reader can see is separate.

## 9. What this does not answer

- **Nothing about push-to-talk.** Capture, the key binding, barge-in and live partial
  transcription are 2d's design, not this probe's. This measures one thing: which engine
  hears the words.
- **Nothing about live/streaming behaviour.** Both engines are measured on complete
  recorded utterances. `SpeechTranscriber` is built for long-form streaming and Whisper
  is not; if 2d wants live partials, that is a second and different measurement.
- **Nothing about a second speaker, or a noisy room.** One operator, one room. That is
  the population Wakil has (§2 of the charter).
- **Nothing about the cloud tier.** Out of scope by §2.

## 10. The resolver measured — 2026-10-06

**Added for `2d-i`'s design. §1 to §9 are untouched.** The question was whether near
matching (approximate spelling) earns a place beside §6.2's fold, and how much noise each
adds. The pass mark was fixed with the operator before any audio: near matching ships only
if it recovers **at least 3 more** of 29 identifiers than fold alone, with **at most 3 more**
wrong suggestions.

**Two recordings**, Apple `SpeechAnalyzer`, the operator's voice, 2026-10-06:
- **Set 1** is §3's 25 utterances, re-recorded because §6's transcripts were never
  committed and `/tmp` had been cleaned. Transcripts: `scripts/probe/stt-2026-10-06-apple.tsv`.
- **Set 2** is 25 new utterances, written and frozen with the scorer *before* recording,
  four of them carrying abbreviations. `scripts/probe/stt-set2/`.

The vocabulary is §6.2's premise made concrete: compound names and file names from this
repository's tracked files (about 16,000), plus Wakil's own short lists — orgs,
environments, MCP tool names, acceptance tables and 3,000 synthetic Jira keys.

| | Set 1 | Set 2 |
|---|---|---|
| Exact, no resolver | 3 / 29 | 4 / 29 |
| Fold | +6, 6 wrong | +11, 2 wrong |
| Fold + near against every name | +7 more, +19 more wrong — fails | — |
| Fold + near against short lists only | +4 more, +3 more wrong — passes | +1 more, +1 more wrong — **fails** |

**Near matching against short lists was chosen after reading set 1**, which is why set 2
exists: the same discipline as §5, applied to a method rather than an engine. It failed.
`2d-i` ships fold only.

**Every wrong fold suggestion is a real name**, not junk: `operatorOnly`, `DBPane`, `MySQL`,
`isActive`, `re-run`. Dropping prose words and single-part names removed one of six. The
noise is the price of a large vocabulary and is carried by the note being a hint.

**Abbreviations: 1 of 4.** `ctx_list_environments` resolved because "CTX" was said as
letters; `activeEnv` ("active M"), `db_set_dsn` ("DB said DSN") and `copiedCtx` ("Kopit
CTX") did not. The operator says abbreviations as words, so expansion is the next category
worth measuring.

**One scorer defect, found and fixed after set 2 was scored**: fold matched the code names
only, not the short lists, against the agreed design. Fixing it added `customers` to set 2
and changed neither verdict. The frozen scorer is `scripts/probe/stt-set2/score2.py`.
