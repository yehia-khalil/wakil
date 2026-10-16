import re, sys

# §3's identifiers, in order. NOTE: this is 29 tokens, not the 30 §3 claims.
IDENT = [
    ["staging","core"], ["edit_quote"], ["writeRef"], ["wakilcore","AssertSQLMutation"],
    ["INI-2835"], ["2c-ii-b"], ["2b-viii"], ["Umbrella"], ["transaction_read_only"],
    ["hardenMySQLWriteConfig"], ["WakilWindow.swift"], ["make app-test"],
    ["phase-2c-ii-acceptance.md"], ["JSONValue"], ["wakil-pm"], ["wakil-acceptance-2"],
    ["edit_bit"], ["ctx_adopt_provider"], ["Invariant 6"], ["writeGate","production"],
    ["paths.go","internal/wakilcore"], ["acc-staging-core-write"], ["describeEditability"],
    ["wakilacc"], ["events"],
]

def exact(ident, text):
    # §4: exact, case-sensitive, surrounding punctuation normalised away.
    return re.search(r'(?<![\w.-])' + re.escape(ident) + r'(?![\w-])', text) is not None

def squash(s):
    return re.sub(r'[^a-z0-9.]', '', s.lower())

def recoverable(ident, text):
    # Not part of §4's score. Measures how many misses a deterministic
    # normaliser against a KNOWN identifier list would recover: case, spaces,
    # hyphens, underscores and apostrophes folded away.
    return squash(ident) in squash(text)

def score(block):
    e = r = 0
    rows = []
    for i, idents in enumerate(IDENT):
        line = block[i]
        for ident in idents:
            if exact(ident, line):      e += 1; rows.append((i+1, ident, "EXACT"))
            elif recoverable(ident, line): r += 1; rows.append((i+1, ident, "recoverable"))
            else:                       rows.append((i+1, ident, "miss"))
    return e, r, rows

def parse(path, header):
    out, on = [], False
    for ln in open(path):
        if ln.startswith("## "):
            on = header in ln; continue
        if on and "\t" in ln:
            out.append(ln.rstrip("\n").split("\t")[-1])
    return out

apple = parse(sys.argv[1], "Apple")
whisp = parse(sys.argv[1], "WhisperKit")
total = sum(len(x) for x in IDENT)
for name, block in (("Apple", apple), ("WhisperKit", whisp)):
    assert len(block) == 25, f"{name}: {len(block)} lines, expected 25"
    e, r, rows = score(block)
    print(f"{name:12} exact {e}/{total}   +recoverable {e+r}/{total}")
    print("   misses:", ", ".join(f"{n}:{i}" for n,i,s in rows if s=="miss"))
    print("   recoverable:", ", ".join(f"{n}:{i}" for n,i,s in rows if s=="recoverable"))
    print()
