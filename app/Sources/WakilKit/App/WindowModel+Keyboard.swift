import Foundation

/// What `ctx_set_key` did: took the chord (naming the command it came from, if any), or refused
/// it with the sentence the row shows.
public enum KeySetOutcome: Equatable, Sendable {
    case took(String?)
    case refused(String)
}

/// What `setKey` does to a command: give it a chord, leave it with none, or put its default back.
public enum KeyChange: Equatable, Sendable {
    case chord(KeyChord)
    case clear
    case restoreDefault
}

extension WindowModel {
    /// Re-reads the keymap's overrides. An unreadable settings.json puts the defaults in force and
    /// its error in `keymapError`; a failed read keeps what the window had, as the browser's does.
    public func refreshKeymap() async {
        guard let result = try? await registry.dispatch(
                  name: "ctx_keyboard", params: .object([:]), origin: .ui,
                  caller: DispatchCaller(place: place, session: nil), confirmation: nil),
              let stored = decodeKeyboard(fromResult: result)
        else { return }
        keymapError = stored.appError
        keymap = Keymap(overrides: stored.appError == nil ? stored.keys : [:])
    }

    /// Changes `id`'s chord through `ctx_set_key`, then re-reads the keymap.
    public func setKey(_ id: String, _ change: KeyChange) async -> KeySetOutcome {
        let chord: JSONValue
        switch change {
        case .chord(let c): chord = .string(c.text)
        case .clear: chord = .string("")
        case .restoreDefault: chord = .null
        }
        let outcome: KeySetOutcome
        do {
            let reply = try await registry.dispatch(
                name: "ctx_set_key", params: .object(["id": .string(id), "chord": chord]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            if case .object(let o) = reply, case .string(let from)? = o["tookFrom"] {
                outcome = .took(from)
            } else {
                outcome = .took(nil)
            }
        } catch {
            outcome = .refused(Self.refusalSentence(error))
        }
        await refreshKeymap()
        return outcome
    }

    /// Writes the whole override map through `ctx_set_keys` (Undo, Restore All), then re-reads
    /// the keymap. Answers the refusal's sentence, or nil.
    public func setKeys(_ overrides: [String: String]) async -> String? {
        var refusal: String?
        do {
            _ = try await registry.dispatch(
                name: "ctx_set_keys", params: .object(["keys": .object(overrides.mapValues { .string($0) })]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            refusal = Self.refusalSentence(error)
        }
        await refreshKeymap()
        return refusal
    }

    /// A press: the focused pane kind's command first, then the anywhere one, each until one acts.
    /// False when none does, so the key goes on to whatever holds the keyboard.
    public func keyPressed(_ chord: KeyChord) async -> Bool {
        let focused = layoutSnapshot.focusedId.flatMap { id in layoutSnapshot.panes.first { $0.id == id } }
        for id in keymap.resolve(chord, paneKind: focused?.kind) where await runKeyCommand(id) {
            return true
        }
        return false
    }

    /// Runs one command by its `KeyCommand` id, through the model method its menu item calls.
    /// False means declined (a browser key with no browser pane focused, say) or unknown. A
    /// command that needs a focused pane and finds none does nothing and still claims the key,
    /// as its menu item does.
    public func runKeyCommand(_ id: String) async -> Bool {
        if id.hasPrefix("browser.") {
            guard let key = Self.browserKeys[id] else { return false }
            return await browserKey(key)
        }
        switch id {
        case "conversation.new": await dispatchSessionNew()
        case "conversation.close": await dispatchSessionClose()
        case "pane.maximize": await commandReturn()
        case "pane.close":
            if layoutSnapshot.focusedId != nil { await closeFocusedTabOrPane() }
        case "pane.toggleDensity":
            if let pane = layoutSnapshot.focusedId { await toggleDensity(id: pane) }
        case "editor.newScratch": await newScratch()
        case "editor.showFiles": await toggleEditorColumn(.files)
        case "editor.searchFiles": await toggleEditorColumn(.search)
        case "editor.showChanges": await toggleEditorColumn(.changes)
        case "editor.save":
            if layoutSnapshot.focusedId != nil { await saveFocusedEditor() }
        case "window.organisation": showOrgPlane = true
        case "window.open": paletteKey(.open)
        case "window.commands": paletteKey(.commands)
        case "window.settings": await openSettings()
        case "window.toggleRail": await toggleRail()
        default: return false
        }
        return true
    }

    private static let browserKeys: [String: BrowserKey] = {
        var keys: [String: BrowserKey] = [
            "browser.newTab": .newTab, "browser.closeTab": .closeTab,
            "browser.findPrevious": .findPrevious, "browser.reopenTab": .reopenTab,
            "browser.focusAddress": .focusAddress, "browser.reload": .reload,
            "browser.back": .back, "browser.forward": .forward, "browser.bookmark": .bookmark,
            "browser.copyURL": .copyURL, "browser.find": .find, "browser.findNext": .findNext,
            "browser.zoomIn": .zoomIn, "browser.zoomOut": .zoomOut, "browser.zoomReset": .zoomReset,
            "browser.showNextTab": .nextTab, "browser.showPreviousTab": .previousTab,
            "browser.nextTab": .nextTab, "browser.previousTab": .previousTab,
            "browser.lastTab": .tab(9), "browser.toggleTabColumn": .toggleTabColumn,
        ]
        for n in 1...8 { keys["browser.tab\(n)"] = .tab(n) }
        return keys
    }()

    /// The refusal's own sentence: a server error's message without the action's name in front.
    private static func refusalSentence(_ error: Error) -> String {
        if case StandardActionError.serverError(_, let message) = error { return message }
        return "\(error)"
    }
}
