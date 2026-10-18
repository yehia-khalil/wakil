# 3b-iv-b: file icons by language — in the Files tree, the Changes view and on editor tabs

**Date:** 2026-10-18
**Status:** design approved by the operator 2026-10-18, section by section
**Sub-phase:** 3b-iv-b, which follows 3b-iv (main fc78372). It waits on nothing. The `-b` suffix
follows 3b-ii-b: a small follow-on that does not renumber the phases after it.

---

## Problem

Every file row in the Files tree and the Changes view, and every editor tab, is a bare
monospaced name. Finding the Go
file among JSON and Markdown means reading each name. An icon per language lets the eye sort
the list before reading it.

## Decisions the operator took during this design (2026-10-18)

- **Single-colour icons, drawn in the name's own colour and opacity.** Brand colours (the VS
  Code default) would break design-language §5, which keeps green, amber and red for meaning
  only, and would clash with the tree's git status letters.
- **Tree rows, Changes rows and editor tabs.** Changes rows were first left out (they lead with a
  git letter) and added at the operator's request the same day. Search results lead with a
  path and keep no icon.
- **The icons are the Seti font** — VS Code's default file-icon set, single-colour glyphs, MIT
  licence (© 2014 Jesse Weed), 37 KB as `seti.woff`. SF Symbols were rejected: they have no
  Go, PHP, Python or YAML shapes.
- **Files only.** Folders, roots and repositories keep their chevron and look as today. A file's
  icon sits in the chevron column, which is empty on file rows now, so names stay aligned and no
  row grows.
- **`editorLanguage(forPath:)` decides the icon**, the same mapping that picks Monaco's syntax
  highlighting, so a file's icon always matches how it is coloured. No filename specials:
  `package.json` is JSON, `Makefile` is the plain page.

## What the operator gets

- **Files tree:** each file row shows its language's glyph in the chevron column, in the name's
  colour and opacity — a dimmed (gitignored) row dims its icon, a selected row lights it.
- **Changes view:** each file row shows the glyph after its status letter and before the name —
  `M ‹go› main.go  cmd/api` — in the name's colour (0.9).
- **Editor tabs:** the same glyph sits before the tab's title, in the title's colour (full on
  the active tab, 0.62 on the others). A diff tab shows the glyph of the file it compares. A tab
  with no path (⌘T's scratch tab) shows the plain page.
- **Fallback:** a language with no Seti glyph (`ini`, `plaintext`) or a file with no mapped
  language shows the plain page.

| Language id | Seti glyph | Code point |
|---|---|---|
| go | `_go2` | U+E03A |
| swift | `_swift` | U+E092 |
| php | `_php` | U+E070 |
| typescript | `_typescript` | U+E099 |
| javascript | `_javascript` | U+E051 |
| json | `_json` | U+E055 |
| yaml | `_yml` | U+E0A7 |
| sql | `_db` | U+E022 |
| markdown | `_markdown` | U+E060 |
| html | `_html_3` | U+E048 |
| css | `_css` | U+E01D |
| scss | `_sass` | U+E084 |
| python | `_python` | U+E07B |
| shell | `_shell` | U+E089 |
| xml | `_xml` | U+E0A5 |
| dockerfile | `_docker` | U+E025 |
| anything else | `_default` | U+E023 |

The code points are those in VS Code's `extensions/theme-seti/icons/vs-seti-icon-theme.json`
for the `seti.woff` bundled with them; the two files are taken from the same VS Code commit.

## What it does not do

- No brand colours, no icon themes, no setting to turn icons off.
- No folder icons, no filename-specific icons (npm, git, make).
- No icons in Search, ⌘P or anywhere else.

## Design

### WakilKit — `app/Sources/WakilKit/Editor/EditorTabs.swift`

- `public func editorFileGlyph(forPath path: String) -> Character`, beside
  `editorLanguage(forPath:)`: maps the language id through the table above, else U+E023.
  Pure; no font knowledge beyond the code points.

### WakilApp

- **Resources:** `app/Resources/seti/seti.woff` and `app/Resources/seti/LICENSE` (Seti's MIT
  text), added to the WakilApp target as `.copy("../../Resources/seti")`, beside Monaco.
- **`EditorFileIcon`** (a small view in `EditorColumn.swift`, used by `EditorPane.swift` too):
  registers the font once per process with `CTFontManagerRegisterFontsForURL(…, .process, …)`
  (probed 2026-10-18: macOS loads the `.woff` as is, family name `seti`) and draws
  `Text(String(glyph)).font(.custom("seti", size:))` in the caller's colour. If registration
  failed, it draws nothing, so the row looks as it does today rather than showing a missing-glyph
  box.
- **`rowLabel`**: for `.file` rows the icon replaces the 10 pt `Spacer` in the chevron column.
  `.note` rows keep the spacer.
- **`changesRow`**: the icon sits between the 18 pt status-letter column and the label, with
  5 pt after it.
- **`tabView`**: the icon sits between the active-tab tick and the title.
- **Accessibility:** the icon is decorative and `.accessibilityHidden(true)`. Tree, Changes and
  tab rows combine their children into one label; a labelled icon would change those labels,
  which VoiceOver reads and existing e2e checks match on.

### Interaction rules

None applies: the icons are static and take no input. Nothing in PRODUCT.md §Interaction Rules
changes.

## Errors and edges

- **The font fails to load** (missing resource, CoreText refuses it): no icons anywhere; the
  tree and tabs look as before 3b-iv-b. Nothing else is affected.
- **Glyph size:** Seti's glyphs carry their own padding (VS Code draws them at 150 % of the
  label size). The size is chosen at build so the glyph's visible height matches the name's
  cap height and fits the 10 pt column; the walk judges it.

## Testing

- **Swift** (`WakilKitTests/EditorTabsTests.swift`): `editorFileGlyph` for one path per row of
  the table, `ini`, an extensionless name and a `Dockerfile`.
- **e2e** (the auditor, at Cover): the icon is hidden from accessibility, so checks cannot see
  it; the existing tree, Changes and tab checks prove their labels did not change.
- **Walk:** the icons show on tree file rows, Changes rows and tabs; single-colour, aligned with
  the chevrons, dimmed on gitignored rows; none on folders or Search results.

## How it lands — one PR

Small enough for one unit of work: the mapping and its test, the font and its licence, the view,
the three call sites, the `design-language.md` line. Then Cover and Walk.

## Charter changes this sub-phase makes

- **`design-language.md`**, the Files tree passage: one sentence — tree and Changes file rows and editor tabs
  show a single-colour Seti glyph for the file's language, in the name's colour.
- No Invariant, no Decision: nothing is written, nothing is priced.
