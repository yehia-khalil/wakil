# sttspike — the STT probe harness

The instrument behind `docs/wakil/2d-stt-probe.md`. Kept in the repository, unlike this
project's other probe spikes, for one reason: it produced a result the charter now rests
on (open question 10, closed on Apple) and `2d-i` will want to re-run it against the
resolver. A throwaway in `/tmp` would have made that result unreproducible.

```
swift build -c release
./.build/release/sttspike record <out-dir>          # walk §3's 25 utterances
./.build/release/sttspike <dir-of-audio> [apple|whisper]
```

Score the output with `../stt-score.py`. Diagnostic env vars — `STTSPIKE_NO_PROMPT`,
`STTSPIKE_NO_CONTEXT`, `STTSPIKE_PROMPT`, `STTSPIKE_REUSE`, `STTSPIKE_NO_TS`,
`STTSPIKE_NO_PREFILL` — are what established §6.1's finding that both vendors' biasing
APIs are inert, and are kept so that finding can be re-checked against a later SDK.

**Not built by `make`.** It targets macOS 26 and pulls WhisperKit, neither of which the
app needs.
