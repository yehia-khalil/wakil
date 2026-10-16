"""Throwaway: fold-only vs fold+near resolution against a vocabulary.
usage: [TRUTH=utterances.tsv] NEARVOCAB=vocab-small.txt score2.py <sttspike-output.tsv> <fold-vocab.txt> [repo]"""
import os, re, sys
TSV, VOCAB = sys.argv[1], sys.argv[2]
REPO = sys.argv[3] if len(sys.argv) > 3 else os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.."))
ns = {}; exec(open(os.path.join(REPO, "scripts/probe/stt-score.py")).read().split("def exact")[0], ns)
IDENT = ns["IDENT"]  # 25 lists, utterance i+1
PRE_REG = 0.80; SENS = [0.75, 0.80, 0.85]; MIN_LEN = 5; MAXN = 6

def fold(s): return re.sub(r'[^a-z0-9.]', '', s.lower())
def exact(ident, text):  # stt-score.py §4 rule
    return re.search(r'(?<![\w.-])' + re.escape(ident) + r'(?![\w-])', text) is not None

def lev(a, b):
    if abs(len(a) - len(b)) > max(len(a), len(b)) * 0.25 + 1: return 99
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (ca != cb)))
        prev = cur
    return prev[-1]
def sim(a, b): return 1 - lev(a, b) / max(len(a), len(b))

vocab = [v for v in open(VOCAB).read().split("\n") if v]
by_fold = {}
for v in vocab: by_fold.setdefault(fold(v), []).append(v)
folds = list(by_fold)
NEAR=os.environ.get('NEARVOCAB')
near_by_fold={}
if NEAR:
    for v in open(NEAR).read().split('\n'):
        if v: near_by_fold.setdefault(fold(v),[]).append(v)
else: near_by_fold=by_fold
near_folds=list(near_by_fold)

def parse(path):
    out, on = {}, False
    for ln in open(path):
        if ln.startswith("## "): on = ln.startswith("## Apple"); continue
        if not on or "\t" not in ln: continue
        name, _, text = ln.rstrip("\n").split("\t", 2)
        m = re.match(r'(\d+)', os.path.basename(name))
        if m: out[int(m.group(1))] = text
    return out

def resolve(text, near_th=None):
    """Longest-first, non-overlapping n-grams. Returns [(phrase, [entries], how)]."""
    words = re.findall(r"[\w.'-]+", text)
    used = [False] * len(words); sugg = []
    for n in range(min(MAXN, len(words)), 0, -1):
        for i in range(len(words) - n + 1):
            if any(used[i:i+n]): continue
            phrase = " ".join(words[i:i+n]); f = fold(phrase)
            if not f: continue
            hits = by_fold.get(f)
            if hits:
                if n == 1 and words[i].strip(".'") in hits:   # already exact: nothing to resolve
                    for k in range(i, i+n): used[k] = True
                    continue
                sugg.append((phrase, hits, "fold")); 
                for k in range(i, i+n): used[k] = True
    if near_th is not None:
        # Best similarity first (then longer), so a long n-gram cannot shadow a closer short one.
        cands = []
        for n in range(min(MAXN, len(words)), 0, -1):
            for i in range(len(words) - n + 1):
                if any(used[i:i+n]): continue
                f = fold(" ".join(words[i:i+n]))
                if len(f) < MIN_LEN: continue
                best, bs = None, 0
                for v in near_folds:
                    if len(v) < MIN_LEN: continue
                    sv = sim(f, v)
                    if sv > bs: best, bs = v, sv
                if best and bs >= 1.0: continue  # already says it: nothing to resolve
                if best and bs >= near_th: cands.append((bs, n, i, best))
        for bs, n, i, best in sorted(cands, key=lambda c: (-c[0], -c[1])):
            if any(used[i:i+n]): continue
            sugg.append((" ".join(words[i:i+n]), [near_by_fold[best][0]], f"near {bs:.2f}"))
            for k in range(i, i+n): used[k] = True
    return sugg

def score(trans, near_th):
    rec = wrong = 0; detail = []
    for u in sorted(trans):
        if not 1 <= u <= len(IDENT): continue
        text, truth = trans[u], IDENT[u-1]
        sugg = resolve(text, near_th)
        suggested = {e for _, es, _ in sugg for e in es}
        for t in truth:
            if not exact(t, text) and t in suggested: rec += 1
        for phrase, es, how in sugg:
            bad = [e for e in es if e not in truth]
            # a fold hit listing several entries counts wrong only if none is right
            if len(bad) == len(es): wrong += 1
            detail.append((u, phrase, es[:4], how, "ok" if len(bad) < len(es) else "WRONG"))
    return rec, wrong, detail

TRUTH=os.environ.get('TRUTH'); KIND={}
if TRUTH:
    rows=[l.rstrip('\n').split('\t') for l in open(TRUTH) if l.strip() and not l.startswith('#')]
    IDENT=[r[1].split(',') for r in rows]; KIND={i+1:r[2] for i,r in enumerate(rows)}
trans = parse(TSV)
print(f"{len(trans)} utterances, {len(vocab)} vocab entries")
fr, fw, fd = score(trans, None)
print(f"\nfold-only: recovered {fr}, wrong suggestions {fw}")
for d in fd: print("  ", *d, sep=" | ")
res = {}
for th in SENS:
    r, w, dd = score(trans, th); res[th] = (r, w)
    print(f"\nfold+near @{th}{' (pre-registered)' if th == PRE_REG else ''}: recovered {r}, wrong {w}")
    if th == PRE_REG:
        for d in dd:
            if d[3].startswith("near"): print("  ", *d, sep=" | ")
r, w = res[PRE_REG]
ok = (r - fr) >= 3 and (w - fw) <= 3
print(f"\nVERDICT @0.80: near +{r-fr} recovered, +{w-fw} wrong -> {'PASS: near matching goes into 2d-i' if ok else 'FAIL: 2d-i ships fold-only'}")
