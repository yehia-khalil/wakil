import os, re, subprocess, sys
REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.."))
OUT = "vocab-code.txt"
SKIP_DIR = re.compile(r'(^|/)(vendor|node_modules|\.build|build|dist|generated|Generated)/')
SKIP_FILE = re.compile(r'(\.(sum|lock|resolved|png|jpg|jpeg|gif|ico|pdf|wav|m4a|caf|aiff|icns|ttf|otf|woff2?|zip|bin|md|txt|html|jsonl)$)|(^|/)(go\.sum|Package\.resolved|package-lock\.json)$')
TOKEN = re.compile(r'[A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+|[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+|[A-Za-z][A-Za-z0-9]*')
CAMEL = re.compile(r'[a-z0-9][A-Z]|[A-Z][A-Z][a-z]')
def compound(t):
    if '_' in t or '-' in t:
        return len([p for p in re.split(r'[_-]', t) if p]) >= 2 and not re.fullmatch(r'-+|_+', t)
    if '.' in t:
        return bool(re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z][A-Za-z0-9]{0,5}', t))  # dotted file names
    return bool(CAMEL.search(t))
files = subprocess.run(["git", "-C", REPO, "ls-files"], capture_output=True, text=True, check=True).stdout.split()
vocab = set()
for f in files:
    if SKIP_DIR.search(f) or SKIP_FILE.search(f): continue
    vocab.add(os.path.basename(f))
    try:
        data = open(os.path.join(REPO, f), 'rb').read()
    except OSError: continue
    if b'\0' in data[:4096]: continue
    for t in TOKEN.findall(data.decode('utf-8', 'replace')):
        t = t.strip('-_.')
        if len(t) >= 4 and compound(t): vocab.add(t)
sys.path.insert(0, os.path.join(REPO, "scripts/probe"))
from importlib import util
spec = util.spec_from_file_location("sttscore", os.path.join(REPO, "scripts/probe/stt-score.py"))
src = open(spec.origin).read()
ns = {}; exec(src.split("def exact")[0], ns)
for idents in ns["IDENT"]: vocab.update(idents)
vocab.update(["initech", "Umbrella", "staging", "production", "local",
              "edit_quote", "edit_bit", "transaction_read_only", "events", "core", "wakilacc"])
with open(OUT, "w") as fh:
    fh.write("\n".join(sorted(vocab)) + "\n")
print(len(vocab), "entries ->", OUT)
