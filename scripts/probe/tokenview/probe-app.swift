// scripts/probe/tokenview/probe-app.swift — Amendment 10's spike. Throwaway; kept so the answer
// can be re-measured. Build: swiftc -parse-as-library -o "$OUT/token-probe" probe-app.swift
import AppKit

/// Every event the probe sees, one per line, to $PROBE_LOG (default ./probe.log): the text as
/// `/a/⟨id⟩/b` (a token drawn as ⟨name⟩), the selection, and presses.
func log(_ line: String) {
    let path = ProcessInfo.processInfo.environment["PROBE_LOG"] ?? "probe.log"
    let data = (line + "\n").data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

final class ProbeAttachment: NSTextAttachment {
    let name: String
    weak var textView: ProbeTextView?
    init(name: String) {
        self.name = name
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        bounds = CGRect(x: 0, y: -4, width: 46, height: 17)
    }
    required init?(coder: NSCoder) { nil }
    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        // Diagnostic: whether TextKit 2 asked for the view at all (the self-check found it does
        // not, off-screen).
        log("viewProvider asked")
        let provider = ProbeProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class ProbeProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        view = ProbeTokenView(attachment: textAttachment as! ProbeAttachment)
    }
}

final class ProbeTokenView: NSView {
    let attachment: ProbeAttachment
    let close: NSButton
    init(attachment: ProbeAttachment) {
        self.attachment = attachment
        close = NSButton(title: "×", target: nil, action: nil)
        super.init(frame: CGRect(x: 0, y: 0, width: 46, height: 17))
        let label = NSTextField(labelWithString: attachment.name)
        label.frame = CGRect(x: 5, y: 0, width: 24, height: 16)
        addSubview(label)
        close.isBordered = false
        close.frame = CGRect(x: 30, y: 0, width: 14, height: 16)
        close.setAccessibilityIdentifier("probe.part.1.remove")
        addSubview(close)
        setAccessibilityIdentifier("probe.part.1.token")
        close.target = self; close.action = #selector(closePressed)
        attachment.textView?.tokenViews.add(self)
    }
    required init?(coder: NSCoder) { nil }
    // Spike result 1 (2026-10-04): TextKit 2 draws this view but AppKit leaves it out of the AX
    // tree — the AXTextArea reported no children. So the probe exposes it itself: a group whose
    // one child is the × button, parented to the text view, which lists it among its children.
    // Frames need no help: both are real views in the window, so AppKit derives them.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { [close] }
    override func accessibilityParent() -> Any? { attachment.textView ?? super.accessibilityParent() }
    override func accessibilityPerformPress() -> Bool {
        log("token-pressed"); attachment.textView?.select(attachment); return true
    }
    override func mouseDown(with event: NSEvent) { attachment.textView?.select(attachment) }
    override func mouseDragged(with event: NSEvent) {
        _ = attachment.textView?.dragSelection(with: event, offset: .zero, slideBack: true)
    }
    @objc func closePressed() { log("pressed"); attachment.textView?.remove(attachment) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

final class ProbeTextView: NSTextView {
    var tag_ = ""
    /// Every token view a provider has made for this text view. Weak: TextKit 2 makes and drops
    /// them as it lays out, and only the ones still in the view tree are exposed.
    let tokenViews = NSHashTable<ProbeTokenView>.weakObjects()
    var exposedTokens: [ProbeTokenView] { tokenViews.allObjects.filter { $0.superview != nil } }
    // The AX children are the token groups and nothing else, and neither entry point calls super.
    //
    // Spike run 2 (2026-10-04) crashed on stack overflow: NSTextView's `accessibilityChildren()`
    // is implemented by going through the LEGACY `accessibilityAttributeValue(.children)`, so an
    // override of each that called the other through super recursed without end (crash report:
    // accessibilityChildren → NSAccessibilityGetObjectValueForAttribute → …UsingLegacyAPI →
    // accessibilityAttributeValue → accessibilityChildren → …). Run 1 measured the text area with
    // no children of its own, so dropping super's list loses nothing that was there.
    override func accessibilityChildren() -> [Any]? { exposedTokens }
    /// Run 2's stack shows AppKit asks this class through the legacy entry point, so it is the
    /// one that must answer; it answers with the same list and never re-enters either method.
    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute == .children { return exposedTokens }
        return super.accessibilityAttributeValue(attribute)
    }
    func range(of attachment: ProbeAttachment) -> NSRange? {
        var found: NSRange?
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage!.length)) { value, range, stop in
            if (value as AnyObject) === attachment { found = range; stop.pointee = true }
        }
        return found
    }
    func select(_ attachment: ProbeAttachment) {
        guard let range = range(of: attachment) else { return }
        window?.makeFirstResponder(self); setSelectedRange(range)
    }
    func remove(_ attachment: ProbeAttachment) {
        guard let range = range(of: attachment) else { return }
        insertText("", replacementRange: range)
    }
    var shown: String {
        guard let storage = textStorage else { return "" }
        var out = ""
        let string = storage.string as NSString
        for index in 0..<string.length {
            if let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ProbeAttachment {
                out += "⟨\(a.name)⟩"
            } else if let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment {
                out += "⟨foreign:\(type(of: a))⟩"
            } else {
                out += String(utf16CodeUnits: [string.character(at: index)], count: 1)
            }
        }
        return out
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    func make(_ id: String, frame: CGRect, withToken: Bool) -> ProbeTextView {
        let view = ProbeTextView(usingTextLayoutManager: true)
        view.frame = frame
        view.tag_ = id
        view.isRichText = true
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.delegate = self
        view.setAccessibilityIdentifier(id)
        if withToken {
            let attrs: [NSAttributedString.Key: Any] = [.font: view.font!]
            let text = NSMutableAttributedString(string: "/a/", attributes: attrs)
            let token = ProbeAttachment(name: "id"); token.textView = view
            text.append(NSAttributedString(attachment: token))
            text.append(NSAttributedString(string: "/b", attributes: attrs))
            view.textStorage?.setAttributedString(text)
        }
        return view
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TokenProbe"
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(make("probe.editor", frame: CGRect(x: 10, y: 90, width: 400, height: 40), withToken: true))
        content.addSubview(make("probe.other", frame: CGRect(x: 10, y: 20, width: 400, height: 40), withToken: false))
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("ready")
        // Diagnostic for the run's log: what the editor offers the AX tree once laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let editor = content.subviews.first as? ProbeTextView else { return }
            let ids = editor.exposedTokens.map {
                "\($0.accessibilityIdentifier())>\($0.close.accessibilityIdentifier())"
            }
            log("ax editor.children=\(editor.accessibilityChildren()?.count ?? 0) tokens=\(ids)")
        }
    }
    func textDidChange(_ n: Notification) {
        guard let v = n.object as? ProbeTextView else { return }
        log("\(v.tag_) text=\(v.shown)")
    }
    func textViewDidChangeSelection(_ n: Notification) {
        guard let v = n.object as? ProbeTextView else { return }
        let r = v.selectedRange()
        log("\(v.tag_) selection=\(r.location),\(r.length)")
    }
}

/// `token-probe --self-check`: an off-screen window never ordered in, never activated, nothing on screen. Builds the
/// editor, forces TextKit 2 layout, and walks the AX children to depth 4 through both entry
/// points. Exit 0 when the walk is finite and reaches `probe.part.1.remove` as an AXButton.
@available(macOS, deprecated: 10.10)
func selfCheck() -> Never {
    let delegate = Delegate()
    let editor = delegate.make("probe.editor", frame: CGRect(x: 0, y: 0, width: 400, height: 40), withToken: true)
    // TextKit 2 makes attachment views only for a viewport inside a window, so the editor gets one
    // that is never ordered in: it is not on screen, takes no focus, and the app never activates.
    let offscreen = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 60),
                             styleMask: [.borderless], backing: .buffered, defer: true)
    offscreen.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 60))
    offscreen.contentView?.addSubview(editor)
    if let tlm = editor.textLayoutManager {
        tlm.invalidateLayout(for: tlm.documentRange)
        tlm.ensureLayout(for: tlm.documentRange)
        tlm.textViewportLayoutController.layoutViewport()
    }
    editor.layoutSubtreeIfNeeded()
    editor.display()
    // Attachment views arrive on a later pass of the run loop, not inside the layout call.
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print("self-check: usesTextAttachmentView=\((editor.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) as? NSTextAttachment)?.usesTextAttachmentView ?? false)")
    var providers = 0, providerViews: [String] = []
    editor.textLayoutManager?.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
        for p in fragment.textAttachmentViewProviders {
            providers += 1
            providerViews.append("\(p.view.map { "\(type(of: $0)) superview=\(String(describing: $0.superview.map { type(of: $0) }))" } ?? "nil")")
        }
        return true
    }
    print("self-check: visibleRect=\(editor.visibleRect) viewport=\(String(describing: editor.textLayoutManager?.textViewportLayoutController.viewportRange)) subviews=\(editor.subviews.map { type(of: $0) })")
    print("self-check: textKit2=\(editor.textLayoutManager != nil) text=\(editor.shown) usage=\(editor.textLayoutManager?.usageBoundsForTextContainer ?? .zero)")
    print("self-check: fragment providers=\(providers) views=\(providerViews)")
    print("self-check: tokenViews made=\(editor.tokenViews.allObjects.count) exposed=\(editor.exposedTokens.count)")
    var found = false
    func walk(_ node: Any, depth: Int, via: String) {
        let view = node as? NSView
        let id = view?.accessibilityIdentifier() ?? ""
        let role = view?.accessibilityRole()?.rawValue ?? "?"
        print("\(via) " + String(repeating: "  ", count: depth) + "\(type(of: node)) role=\(role) id=\(id)")
        if id == "probe.part.1.remove" && role == "AXButton" { found = true }
        guard depth < 4 else { return }
        let kids: [Any]
        if via == "legacy" {
            kids = (view?.accessibilityAttributeValue(.children) as? [Any]) ?? []
        } else {
            kids = view?.accessibilityChildren() ?? []
        }
        for kid in kids { walk(kid, depth: depth + 1, via: via) }
    }
    walk(editor, depth: 0, via: "modern")
    let modernFound = found; found = false
    walk(editor, depth: 0, via: "legacy")
    // Getting here at all is the finiteness check: run 2's loop overflowed the stack instead.
    print("self-check: walk finite through both entry points (depth <= 4)")
    if editor.exposedTokens.isEmpty {
        print("self-check: PASS (finite only) — TextKit 2 made no attachment view off-screen, so the × cannot be reached here; the GUI run decides (a)")
        exit(0)
    }
    let ok = modernFound && found
    print("self-check: \(ok ? "PASS" : "FAIL") reached probe.part.1.remove as AXButton: modern=\(modernFound) legacy=\(found)")
    exit(ok ? 0 : 1)
}

@main enum Probe {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--self-check") { app.setActivationPolicy(.prohibited); selfCheck() }
        app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate; app.run()
    }
}
