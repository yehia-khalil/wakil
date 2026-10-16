# The identifier probe

Two throwaway programs that together answer one question: **does an
`.accessibilityIdentifier` reach `orca computer get-app-state`?**

It does not, and `docs/wakil/agent-e2e-probe.md` §4b records the measurement and
what it cost #250. These files are kept so the answer can be re-measured against a
later Orca rather than re-argued.

```sh
swiftc -o /tmp/ax-probe  probe-app.swift && /tmp/ax-probe &
swiftc -o /tmp/ax-dump   ax-dump.swift

PID=$(pgrep -f ax-probe | head -1)

# What Orca is willing to show.
/Applications/Orca.app/Contents/Resources/bin/orca computer get-app-state \
    --app "pid:$PID" --no-screenshot --json |
  python3 -c "import sys,json;print(json.load(sys.stdin)['result']['snapshot']['treeText'])"

# What is actually on the elements.
/tmp/ax-dump "$PID"
```

`probe-app.swift` draws eight controls, each carrying exactly one candidate
attribute, so the two outputs can be read side by side and the difference is the
answer. `ax-dump.swift` walks the real accessibility tree with
`AXUIElementCopyAttributeValue`, which is the same API `e2e/axresolve` uses.
