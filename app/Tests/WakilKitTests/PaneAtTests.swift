import Testing
@testable import WakilKit

/// 3b-v PR 8: a click anywhere in a pane focuses it. The window watches every mouse-down and
/// asks `paneAt` which pane it landed in — top-most first, in the canvas's own draw order.

private func pane(_ id: String, _ x: Double, _ y: Double, _ w: Double = 300, _ h: Double = 200,
                  kind: String = "editor") -> Pane {
    Pane(id: id, kind: kind, title: id, frame: PaneFrame(x: x, y: y, width: w, height: h))
}

@Suite struct PaneAtTests {
    @Test func aClickInsideOnePaneLandsInIt() {
        let panes = [pane("a", 0, 0), pane("b", 400, 0)]
        #expect(paneAt(x: 450, y: 50, panes: panes, focusedId: "a") == "b")
        #expect(paneAt(x: 10, y: 10, panes: panes, focusedId: "a") == "a")
    }

    @Test func aClickInNoPaneLandsNowhere() {
        let panes = [pane("a", 0, 0), pane("b", 400, 0)]
        #expect(paneAt(x: 350, y: 50, panes: panes, focusedId: "a") == nil)
        #expect(paneAt(x: 50, y: 250, panes: panes, focusedId: "a") == nil)
        #expect(paneAt(x: 50, y: 50, panes: [], focusedId: nil) == nil)
    }

    @Test func overlappingPanesGiveTheLaterOneWhenNeitherIsFocused() {
        let panes = [pane("a", 0, 0), pane("b", 100, 100)]
        #expect(paneAt(x: 150, y: 150, panes: panes, focusedId: nil) == "b")
        #expect(paneAt(x: 150, y: 150, panes: panes, focusedId: "gone") == "b")
    }

    @Test func theFocusedPaneDrawsInFrontSoItTakesTheOverlap() {
        let panes = [pane("a", 0, 0), pane("b", 100, 100)]
        #expect(paneAt(x: 150, y: 150, panes: panes, focusedId: "a") == "a")
        // Outside the focused pane, the one under the point still answers.
        #expect(paneAt(x: 350, y: 250, panes: panes, focusedId: "a") == "b")
    }

    @Test func aSharedEdgeBelongsToThePaneThatStartsThere() {
        let panes = [pane("a", 0, 0), pane("b", 300, 0)]
        #expect(paneAt(x: 300, y: 50, panes: panes, focusedId: "a") == "b")
        #expect(paneAt(x: 0, y: 0, panes: panes, focusedId: nil) == "a")
    }

    @Test func aMaximizedPaneTakesEveryClickWhileItHoldsFocus() {
        // `maximize` sets the pane's frame to the void and focuses it.
        let panes = [pane("a", 0, 0, 1200, 800), pane("b", 100, 100)]
        #expect(paneAt(x: 150, y: 150, panes: panes, focusedId: "a") == "a")
        #expect(paneAt(x: 900, y: 700, panes: panes, focusedId: "a") == "a")
        // Focus moved from the rail: the canvas draws `b` in front, so `b` answers.
        #expect(paneAt(x: 150, y: 150, panes: panes, focusedId: "b") == "b")
    }

    @Test func theSettingsPaneOnTheCanvasIsAPaneLikeAnyOther() {
        let panes = [pane("settings-1", 60, 60, 640, 420, kind: Pane.settingsKind),
                     pane("editor-2", 400, 260)]
        #expect(paneAt(x: 150, y: 120, panes: panes, focusedId: "editor-2") == "settings-1")
        #expect(paneAt(x: 500, y: 300, panes: panes, focusedId: "editor-2") == "editor-2")
        #expect(paneAt(x: 500, y: 300, panes: panes, focusedId: "settings-1") == "settings-1")
    }

    @Test func overTheLandingOnlyTheSettingsPaneIsDrawn() {
        // The overlay draws the settings pane at its own frame; the editor is in the layout
        // but on no screen, focused or not.
        let panes = [pane("editor-1", 0, 0, 900, 700),
                     pane("settings-2", 24, 14, 800, 600, kind: Pane.settingsKind)]
        #expect(paneAt(x: 100, y: 100, panes: panes, focusedId: "editor-1", overLanding: true) == "settings-2")
        #expect(paneAt(x: 5, y: 5, panes: panes, focusedId: "editor-1", overLanding: true) == nil)
        #expect(paneAt(x: 100, y: 100, panes: [pane("editor-1", 0, 0)], focusedId: "editor-1",
                       overLanding: true) == nil)
    }
}

@Suite struct PaneClickFocusTargetTests {
    @Test func aPaneThatIsNotFocusedIsAskedWhereverTheClickLands() {
        #expect(paneClickFocusTarget(target: "settings-1", focusedId: "editor-2", landsOnInput: false) == "settings-1")
        #expect(paneClickFocusTarget(target: "settings-1", focusedId: "editor-2", landsOnInput: true) == "settings-1")
        #expect(paneClickFocusTarget(target: "settings-1", focusedId: nil, landsOnInput: true) == "settings-1")
    }

    @Test func theFocusedPaneIsAskedOnlyOutsideATextInput() {
        // #284: the keyboard may be in the composer; a click on the pane's body brings it back.
        #expect(paneClickFocusTarget(target: "terminal-1", focusedId: "terminal-1", landsOnInput: false) == "terminal-1")
        // A field or the editor in the focused pane takes the keyboard by itself.
        #expect(paneClickFocusTarget(target: "terminal-1", focusedId: "terminal-1", landsOnInput: true) == nil)
    }

    @Test func aClickInNoPaneAsksNothing() {
        #expect(paneClickFocusTarget(target: nil, focusedId: "editor-2", landsOnInput: false) == nil)
    }
}
