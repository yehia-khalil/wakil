import Foundation
import Testing
@testable import WakilKit

@Test func filesSourceListsEveryRootsFilesAsOpenInEditorRows() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["internal/wakilcore/config.go", "main.go"])
    await files.setListing("/p/web", ["src/app.ts"])
    let rows = await FilesSource(files: files, roots: { ["/p/api", "/p/web"] }).entries()
    #expect(rows.map(\.title) == ["config.go", "main.go", "app.ts"])
    #expect(rows[0].subtitle == "internal/wakilcore · api")
    #expect(rows[0].kindLabel == "file" && rows[0].group == .resources)
    #expect(rows[0].action == .openInEditor(path: "/p/api/internal/wakilcore/config.go"))
}

@Test func aRootThatFailsToListIsOneErrorRowAndHidesNoOtherRoot() async {
    let files = FakeFiles()
    await files.setListing("/p/web", ["src/app.ts"])
    await files.setListError("/p/api", "root /p/api is not readable")
    let rows = await FilesSource(files: files, roots: { ["/p/api", "/p/web"] }).entries()
    #expect(rows.contains { $0.isError && $0.title.contains("/p/api is not readable") })
    #expect(rows.contains { $0.title == "app.ts" })
}

@Test func aTruncatedRootStartsWithANoteRowSayingSo() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["main.go"])
    await files.setTruncated("/p/api")
    await files.setListing("/p/web", ["src/app.ts"])
    let rows = await FilesSource(files: files, roots: { ["/p/api", "/p/web"] }).entries()
    #expect(rows.map(\.title) == ["api", "main.go", "app.ts"])
    let note = rows[0]
    #expect(note.isError && note.id == "error:truncated:/p/api")
    #expect(note.subtitle.contains("only the first 1 files are listed and searched; open a deeper root"))
    #expect(!rows.contains { $0.isError && $0.title == "web" })
}

@Test func ignoredFilesAreListedDimmedAndRankBelowEveryTrackedMatch() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["config/env.php"])
    await files.setIgnored("/p/api", [".env"])
    let rows = await FilesSource(files: files, roots: { ["/p/api"] }).entries()
    #expect(rows.first { $0.title == ".env" }?.isDimmed == true)
    #expect(rows.first { $0.title == "env.php" }?.isDimmed == false)
    let ranked = PaletteSearch.rank(rows, query: "env")
    #expect(ranked.map(\.title) == ["env.php", ".env"])
}

@Test func ignoredFilesAreLeftOutWhenTheSettingIsOff() async {
    let files = FakeFiles()
    await files.setListing("/p/api", ["config/env.php"])
    await files.setIgnored("/p/api", [".env"])
    let rows = await FilesSource(files: files, roots: { ["/p/api"] }, showIgnored: { false }).entries()
    #expect(rows.map(\.title) == ["env.php"])
}
