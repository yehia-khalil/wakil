import Foundation
import Testing
@testable import WakilKit

@Suite @MainActor struct WindowModelFastPathTests {
    @Test func theScopeHoldsTheTopTwentyFilesAndEveryPane() async throws {
        let (window, _, files) = await editorWindowParts(roots: ["/p"])
        await window.refreshContext()
        await files.setListing("/p", (1...30).map { "src/confirm\($0).go" } + ["api/confirm.go"])
        await files.put("/p/api/confirm.go", "package api")
        await window.dispatchFromSurface("editor_open", .object(["path": .string("/p/api/confirm.go")]))
        await window.refreshLayout()
        let scope = await window.fastPathScope(for: "open confirm.go")
        #expect(scope.files.count == 20)
        #expect(scope.files.first == "/p/api/confirm.go")
        // A leading verb matches no file, and must not empty the list.
        #expect(await window.fastPathScope(for: "open confirm.go").files.first == "/p/api/confirm.go")
        #expect(scope.panes.map(\.kind) == ["editor"])
        #expect(scope.roots == window.rootPaths)
    }

    @Test func theSchemasAreTheRegistrysForEachAllowedActionItHolds() async throws {
        let (window, _, _) = await editorWindowParts(roots: ["/p"])
        let schemas = await window.fastPathSchemas()
        #expect(schemas["editor_open"] != nil)
        #expect(schemas.keys.allSatisfy { FastPath.allowed[$0] != nil })
    }
}
