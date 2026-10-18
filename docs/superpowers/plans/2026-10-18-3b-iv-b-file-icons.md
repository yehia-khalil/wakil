# 3b-iv-b File Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a single-colour Seti glyph for each file's language on Files tree file rows,
Changes rows and editor tabs.

**Architecture:** WakilKit gets two pure functions that map a path, or a tab, to a Seti code
point through `editorLanguage(forPath:)`. WakilApp bundles VS Code's `seti.woff`, registers it once
per process, and draws the glyph as text in one small view, `EditorFileIcon`, used at three call
sites.

**Tech Stack:** Swift 6, SwiftUI, CoreText (`CTFontManagerRegisterFontsForURL`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-18-3b-iv-b-file-icons-design.md`

## Global Constraints

- Single-colour: the icon takes the colour and opacity of the name beside it; never green, amber
  or red (design-language §5).
- Tree **file** rows, Changes rows and editor tabs only. Folders, roots, repositories, notes,
  Search results and ⌘P get no icon.
- The glyph comes from `editorLanguage(forPath:)` through the spec's table; anything else is
  U+E023 (`_default`). No filename specials.
- The font is `seti.woff` from VS Code commit `00ab0906bad641d5be1d009da16baa5cec66a161`
  (`extensions/theme-seti/icons/seti.woff`, sha256
  `b127762058f89b37b08d76185e3b0558f5c28859e39a3840a27cb28b9739d6e2`), family name `seti`,
  licence: Seti UI's MIT text (© 2014 Jesse Weed).
- If the font fails to register, the icon draws nothing.
- The icon is `.accessibilityHidden(true)`: no row's accessibility label changes.
- Commit messages carry no `Co-Authored-By` trailer and no "Generated with" line.
- macOS floor stays 14.4; no new package dependency.

## Review Focus

1. **A diff tab** (`EditorTab.diff(root:path:group:)`, `tab.path == nil`) — expected: the glyph of the
   compared file, not the page. Pinned in Task 1 (`aDiffTabShowsItsFilesGlyph`).
2. **A scratch tab whose language is set** (`.scratch(number:language: "sql")`) — expected: the
   page, per the spec, not the SQL glyph. Pinned in Task 1 (`aScratchTabShowsThePage`).
3. **Upper-case or compound extensions** (`README.MD`, `app.test.tsx`, `Dockerfile`) — expected:
   the same glyph as their lower-case language. Pinned in Task 1 (`glyphsFollowTheLanguage`).
4. **A gitignored (dimmed) file row** — expected: the icon dims with the name, because it
   inherits the row's `.foregroundStyle` and `.opacity`. Checked at the walk; Task 2 must not set
   its own colour on tree rows.
5. **Every row's accessibility label unchanged** — expected: the existing tree, Changes and tab
   e2e checks still pass. Task 2 hides the icon; Cover runs those checks.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `app/Sources/WakilKit/Editor/EditorTabs.swift` | modify | `editorFileGlyph(forPath:)`, `editorTabGlyph(_:)` beside `editorLanguage(forPath:)` |
| `app/Tests/WakilKitTests/EditorTabsTests.swift` | modify | their tests |
| `app/Resources/seti/seti.woff` | create | the font (binary, pinned above) |
| `app/Resources/seti/LICENSE` | create | Seti UI's MIT licence |
| `app/Package.swift` | modify | `.copy("../../Resources/seti")` |
| `app/Sources/WakilApp/EditorFileIcon.swift` | create | font registration and the glyph view |
| `app/Sources/WakilApp/EditorColumn.swift` | modify | tree `rowLabel`, `changesRow` call sites |
| `app/Sources/WakilApp/EditorPane.swift` | modify | `tabView` call site |
| `docs/wakil/design-language.md` | modify | one sentence in the Files passage |
| `docs/superpowers/specs/2026-10-18-3b-iv-b-file-icons-design.md` | modify | the view lives in its own file (amendment) |

`EditorFileIcon` gets its own file rather than living in `EditorColumn.swift` (the spec's wording):
`EditorColumn.swift` is already over 1,000 lines and the view is used by two files. Task 2 records
this as a one-line amendment in the spec.

---

### Task 1: The glyph mapping (WakilKit)

**Files:**
- Modify: `app/Sources/WakilKit/Editor/EditorTabs.swift` (after `editorLanguage(forPath:)`, ~line 75)
- Test: `app/Tests/WakilKitTests/EditorTabsTests.swift` (after `languageComesFromTheExtension`)

**Interfaces:**
- Consumes: `editorLanguage(forPath:) -> String`, `EditorTab.subject` (`.file(path, _)`,
  `.diff(_, path, _)`, `.scratch(_)`).
- Produces: `public func editorFileGlyph(forPath path: String) -> Character` and
  `public func editorTabGlyph(_ tab: EditorTab) -> Character`.

- [ ] **Step 1: Write the failing tests**

Add to `app/Tests/WakilKitTests/EditorTabsTests.swift`, after `languageComesFromTheExtension`:

```swift
@Test func glyphsFollowTheLanguage() {
    let cases: [(String, Character)] = [
        ("/a/main.go", "\u{E03A}"), ("/a/App.swift", "\u{E092}"), ("/a/index.php", "\u{E070}"),
        ("/a/app.test.tsx", "\u{E099}"), ("/a/b.mjs", "\u{E051}"), ("/a/package.json", "\u{E055}"),
        ("/a/ci.yml", "\u{E0A7}"), ("/a/q.sql", "\u{E022}"), ("/a/README.MD", "\u{E060}"),
        ("/a/x.vue", "\u{E048}"), ("/a/s.css", "\u{E01D}"), ("/a/s.scss", "\u{E084}"),
        ("/a/run.py", "\u{E07B}"), ("/a/go.sh", "\u{E089}"), ("/a/pom.xml", "\u{E0A5}"),
        ("/a/Dockerfile", "\u{E025}"),
    ]
    for (path, glyph) in cases { #expect(editorFileGlyph(forPath: path) == glyph, "\(path)") }
}

@Test func filesWithNoGlyphShowThePage() {
    #expect(editorFileGlyph(forPath: "/a/.env") == "\u{E023}")      // ini
    #expect(editorFileGlyph(forPath: "/a/Makefile") == "\u{E023}")  // plaintext
    #expect(editorFileGlyph(forPath: "/a/LICENSE") == "\u{E023}")
    #expect(editorFileGlyph(forPath: "/a/b.unknown") == "\u{E023}")
}

@Test func aFileTabShowsItsFilesGlyph() {
    #expect(editorTabGlyph(fileTab("/p/api/main.go")) == "\u{E03A}")
}

@Test func aDiffTabShowsItsFilesGlyph() {
    #expect(editorTabGlyph(.diff(root: "/p/api", path: "cmd/main.go", group: .changed)) == "\u{E03A}")
}

@Test func aScratchTabShowsThePage() {
    #expect(editorTabGlyph(.scratch(number: 1, language: "sql")) == "\u{E023}")
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd /Users/yehia/Desktop/scripts/wakil-public/app && ../scripts/swift-test.sh --filter "Glyph|ThePage"`
Expected: build fails with `cannot find 'editorFileGlyph' in scope`.

- [ ] **Step 3: Implement**

Add to `app/Sources/WakilKit/Editor/EditorTabs.swift`, right after `editorLanguage(forPath:)`:

```swift
/// The Seti icon font's glyph for a path (3b-iv-b): its language's, through
/// `editorLanguage(forPath:)`, so the icon always matches the highlighting; else the plain page.
/// Code points from VS Code's `theme-seti/icons/vs-seti-icon-theme.json` at the commit the bundled
/// `seti.woff` came from.
public func editorFileGlyph(forPath path: String) -> Character {
    switch editorLanguage(forPath: path) {
    case "go": "\u{E03A}"
    case "swift": "\u{E092}"
    case "php": "\u{E070}"
    case "typescript": "\u{E099}"
    case "javascript": "\u{E051}"
    case "json": "\u{E055}"
    case "yaml": "\u{E0A7}"
    case "sql": "\u{E022}"
    case "markdown": "\u{E060}"
    case "html": "\u{E048}"
    case "css": "\u{E01D}"
    case "scss": "\u{E084}"
    case "python": "\u{E07B}"
    case "shell": "\u{E089}"
    case "xml": "\u{E0A5}"
    case "dockerfile": "\u{E025}"
    default: "\u{E023}"
    }
}

/// A tab's glyph: a file's or a diff's by its path; a scratch tab's is the plain page.
public func editorTabGlyph(_ tab: EditorTab) -> Character {
    switch tab.subject {
    case .file(let path, _), .diff(_, let path, _): editorFileGlyph(forPath: path)
    case .scratch: "\u{E023}"
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/yehia/Desktop/scripts/wakil-public/app && ../scripts/swift-test.sh --filter "Glyph|ThePage"`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/EditorTabs.swift app/Tests/WakilKitTests/EditorTabsTests.swift
git commit -m "3b-iv-b: kit — a Seti glyph per file language, and per tab"
```

---

### Task 2: The font, the icon view and its three call sites (WakilApp)

**Files:**
- Create: `app/Resources/seti/seti.woff`, `app/Resources/seti/LICENSE`
- Create: `app/Sources/WakilApp/EditorFileIcon.swift`
- Modify: `app/Package.swift:42-46` (WakilApp `resources`)
- Modify: `app/Sources/WakilApp/EditorColumn.swift` — `rowLabel` (~line 313–320), `changesRow` (~line 432–438)
- Modify: `app/Sources/WakilApp/EditorPane.swift` — `tabView` (~line 339–344)
- Modify: `docs/wakil/design-language.md` (Files passage, ~line 456)
- Modify: `docs/superpowers/specs/2026-10-18-3b-iv-b-file-icons-design.md` (amendment)

**Interfaces:**
- Consumes: `editorFileGlyph(forPath:) -> Character`, `editorTabGlyph(_:) -> Character` (Task 1).
- Produces: `struct EditorFileIcon: View` with `init(_ glyph: Character)`.

WakilApp has no test target; this task is proven by `make app-build`, `make app-test` (no
regressions) and, at Cover and the walk, by sight and the existing e2e checks.

- [ ] **Step 1: Add the font and its licence**

```bash
cd /Users/yehia/Desktop/scripts/wakil-public
mkdir -p app/Resources/seti
curl -sfL -o app/Resources/seti/seti.woff https://raw.githubusercontent.com/microsoft/vscode/00ab0906bad641d5be1d009da16baa5cec66a161/extensions/theme-seti/icons/seti.woff
curl -sfL -o app/Resources/seti/LICENSE https://raw.githubusercontent.com/jesseweed/seti-ui/master/LICENSE.md
shasum -a 256 app/Resources/seti/seti.woff
head -3 app/Resources/seti/LICENSE
```

Expected: the hash is `b127762058f89b37b08d76185e3b0558f5c28859e39a3840a27cb28b9739d6e2`; the
licence begins with the MIT text and `Copyright (c) 2014 Jesse Weed`.

- [ ] **Step 2: Bundle it**

In `app/Package.swift`, the WakilApp target's `resources` becomes:

```swift
            resources: [
                .copy("default.metallib"),
                .copy("monaco-host.html"),
                .copy("../../Resources/monaco"),
                // The Seti icon font (3b-iv-b): VS Code's single-colour file icons, MIT.
                .copy("../../Resources/seti"),
            ]),
```

- [ ] **Step 3: Write the view**

Create `app/Sources/WakilApp/EditorFileIcon.swift`:

```swift
import CoreText
import SwiftUI
import WakilKit

/// A file's language icon (3b-iv-b): one Seti glyph, drawn as text so it takes the colour and
/// opacity of the row it sits in. Decorative — hidden from accessibility so no row's label changes.
/// If the font did not register, it draws nothing and the row looks as it did before icons.
struct EditorFileIcon: View {
    let glyph: Character
    init(_ glyph: Character) { self.glyph = glyph }

    /// Registered once per process, on first use.
    private static let available: Bool = {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("seti/seti.woff") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// Seti's glyphs carry their own padding (VS Code draws them at 150 % of the label), so 13 pt
    /// sits at about the cap height of the 11.5–12 pt names. The walk judges it; change it here only.
    static let size: CGFloat = 13

    var body: some View {
        if Self.available {
            Text(String(glyph))
                .font(.custom("seti", size: Self.size))
                .frame(width: 10)
                .accessibilityHidden(true)
        }
    }
}
```

- [ ] **Step 4: Tree file rows**

In `app/Sources/WakilApp/EditorColumn.swift`, `rowLabel`, split the `.file, .note` case:

```swift
            case .file:
                EditorFileIcon(editorFileGlyph(forPath: row.id))
            case .note:
                Spacer().frame(width: 10)
```

`row.id` is the file's absolute path (`EditorTree.swift`: `id // absolute path`). Do not add a
`.foregroundStyle`: the HStack's own (`EditorPaneStyle.text.opacity(0.86)`) and the dimmed row's
`.opacity(0.45)` must reach the icon. If the font did not register, the icon draws nothing and the
column collapses; that is the spec's fallback, so leave it.

- [ ] **Step 5: Changes rows**

In `changesRow`, between the status `Text` and the label `Text`:

```swift
            Text(row.status)
                .foregroundStyle(EditorPaneStyle.tone(gitStatusTone(row.status)))
                .frame(width: 18, alignment: .leading)
            EditorFileIcon(editorFileGlyph(forPath: row.path))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                .padding(.trailing, 5)
            Text(gitRowLabel(row))
```

- [ ] **Step 6: Editor tabs**

In `app/Sources/WakilApp/EditorPane.swift`, `tabView`, between the tick and the title:

```swift
            EditorFileIcon(editorTabGlyph(tab))
                .foregroundStyle(on ? EditorPaneStyle.text : EditorPaneStyle.text.opacity(0.62))
            Text(title)
```

- [ ] **Step 7: The design-language line and the spec amendment**

In `docs/wakil/design-language.md`, in the Files passage, after the sentence ending "the tree
never follows the active file by itself.", add:

```
    3b-iv-b gives file rows, Changes rows and editor tabs a single-colour Seti glyph for the
    file's language, in the name's own colour; folders keep their chevron.
```

Append to the spec:

```
## Amendment — 2026-10-18, while planning

- `EditorFileIcon` lives in its own file, `app/Sources/WakilApp/EditorFileIcon.swift`, not in
  `EditorColumn.swift`: that file is over 1,000 lines and the view is used by two files.
```

- [ ] **Step 8: Build and test**

Run: `cd /Users/yehia/Desktop/scripts/wakil-public && make app-build && make app-test`
Expected: the build succeeds; app-test passes (about 3,020 tests). If one of the known
intermittent tests fails (`ComposerModelTests`, the `EditorSearchTests` debounce test,
`WindowModelTests.aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy`), report it by name;
do not rerun into green.

- [ ] **Step 9: Check the bundle carries the font**

Run: `cd /Users/yehia/Desktop/scripts/wakil-public && make app-bundle && ls app/Wakil.app/Wakil_WakilApp.bundle/Contents/Resources/seti`
Expected: `LICENSE  seti.woff`.

- [ ] **Step 10: Commit**

```bash
git add app/Resources/seti app/Package.swift app/Sources/WakilApp/EditorFileIcon.swift \
  app/Sources/WakilApp/EditorColumn.swift app/Sources/WakilApp/EditorPane.swift \
  docs/wakil/design-language.md docs/superpowers/specs/2026-10-18-3b-iv-b-file-icons-design.md
git commit -m "3b-iv-b: app — Seti icons on tree file rows, Changes rows and editor tabs"
```

---

## After the tasks

- **Cover:** the e2e auditor (`docs/agents/e2e.md`). The icon is hidden from accessibility, so it
  writes no new check for it; it runs the existing tree, Changes and tab checks to prove no
  label changed, and reports the icon itself as covered by the walk.
- **Walk:** the operator, from a runbook the auditor writes: icons on tree file rows, Changes rows
  and tabs; single-colour; aligned with the chevrons; dimmed on gitignored rows; none on
  folders, Search results or ⌘P; the size against the name.
