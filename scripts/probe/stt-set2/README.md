# 2d-i resolver probe — 2026-10-06

Throwaway scorer kept for reproducibility; `2d-stt-probe.md` §10 holds the result.

> `vocab-small.txt`, which this probe scored against, held a private Jira's ticket keys and
> is not published, so the commands below no longer run as written. `vocab-snapshot-*.txt`
> is kept with its ticket keys and org names replaced, because `IdentifierCorpusTests`
> reads it. The result is recorded in `docs/wakil/2d-stt-probe.md`.

```bash
cd scripts/probe/stt-set2
python3 -I vocab_code.py                                  # writes vocab-code.txt from this repo's tracked files
sort -u vocab-code.txt vocab-small.txt > vocab-all.txt    # fold runs against every source
# set 1 (§3's utterances; answers come from ../stt-score.py)
NEARVOCAB=vocab-small.txt python3 -I score2.py ../stt-2026-10-06-apple.tsv vocab-all.txt
# set 2
TRUTH=utterances.tsv NEARVOCAB=vocab-small.txt python3 -I score2.py apple-2026-10-06.tsv vocab-all.txt
```

Recording set 2 again: `../sttspike/.build/release/sttspike record /tmp/sttprobe2 utterances.tsv`.
The vocabulary is rebuilt from the working tree, so counts drift as the repo grows.
