import Foundation

/// A page as the agent reads it, the seam that reads and drives it, and the cap on what goes back
/// (3c-ii). The window implements `BrowserPageDriver`; everything decidable lives here, tested.

public struct BrowserElement: Sendable, Equatable, Codable {
    /// role: textbox textarea checkbox radio select button link other
    public var ref, role, label: String
    public var type, autocomplete, name, id, placeholder: String
    public var value: String?
    public var options: [String]?
    public var href: String?

    public init(ref: String, role: String, label: String, type: String = "", autocomplete: String = "",
                name: String = "", id: String = "", placeholder: String = "",
                value: String? = nil, options: [String]? = nil, href: String? = nil) {
        self.ref = ref; self.role = role; self.label = label
        self.type = type; self.autocomplete = autocomplete; self.name = name
        self.id = id; self.placeholder = placeholder
        self.value = value; self.options = options; self.href = href
    }
}

public struct BrowserPageRead: Sendable, Equatable {
    public var url, title, text: String
    public var elements: [BrowserElement]
    public var framesSkipped: Int

    public init(url: String, title: String, text: String, elements: [BrowserElement], framesSkipped: Int = 0) {
        self.url = url; self.title = title; self.text = text
        self.elements = elements; self.framesSkipped = framesSkipped
    }
}

public enum BrowserKeyName: String, Sendable, CaseIterable {
    case Return, Tab, Escape, ArrowUp, ArrowDown, ArrowLeft, ArrowRight
}

public enum BrowserPageAct: Sendable, Equatable {
    case click(ref: String)
    case type(ref: String, text: String, expect: BrowserElement)
    case select(ref: String, option: String, expect: BrowserElement)
    case press(ref: String, key: BrowserKeyName)
    case scroll(ref: String)

    public var ref: String {
        switch self {
        case .click(let ref), .scroll(let ref): return ref
        case .type(let ref, _, _), .select(let ref, _, _), .press(let ref, _): return ref
        }
    }
}

public struct BrowserActResult: Sendable, Equatable {
    public var url, title: String
    public var loading, navigated: Bool

    public init(url: String, title: String, loading: Bool, navigated: Bool) {
        self.url = url; self.title = title; self.loading = loading; self.navigated = navigated
    }
}

public enum BrowserPageDriverError: Error, Sendable, Equatable {
    case stale, notLoaded, operatorBusy, failed(String)
}

/// The window's: Wakil's script in the `wakil.agent` content world. `scope` nil is the screen's canvas.
public protocol BrowserPageDriver: Sendable {
    func read(scope: LayoutScope?, pane: String, tab: String, firstRef: Int) async throws -> BrowserPageRead
    func describe(scope: LayoutScope?, pane: String, tab: String, ref: String) async throws -> BrowserElement
    func act(scope: LayoutScope?, pane: String, tab: String, _ act: BrowserPageAct) async throws -> BrowserActResult
}

// MARK: - The cap

public let browserPageCap = 204_800

private struct PagePart: Encodable {
    var text: String
    var elements: [BrowserElement]
}

private func pageBytes(_ text: String, _ elements: [BrowserElement]) -> Int {
    (try? JSONEncoder().encode(PagePart(text: text, elements: elements)).count) ?? Int.max
}

/// Keeps the page's text and elements within `limit` bytes of their JSON. Elements go first from the
/// end when they alone are too big; then the text is cut at a character boundary. `cut` says where.
public func browserFitToCap(_ read: BrowserPageRead, limit: Int = browserPageCap) -> (read: BrowserPageRead, cut: String?) {
    if pageBytes(read.text, read.elements) <= limit { return (read, nil) }

    var elements = read.elements
    var dropped = 0
    while !elements.isEmpty, pageBytes("", elements) > limit {
        // Halve the overshoot where it is large, so a huge element list does not cost one encode per element.
        let step = max(1, elements.count / 8)
        let keep = max(0, elements.count - step)
        let candidate = Array(elements.prefix(keep))
        if step > 1, pageBytes("", candidate) <= limit {
            // Overshot: walk back one at a time from the dropped tail.
            var n = keep
            while n < elements.count, pageBytes("", Array(elements.prefix(n + 1))) <= limit { n += 1 }
            dropped += elements.count - n
            elements = Array(elements.prefix(n))
            break
        }
        dropped += elements.count - keep
        elements = candidate
    }

    let chars = Array(read.text)
    var lo = 0, hi = chars.count
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if pageBytes(String(chars[0..<mid]), elements) <= limit { lo = mid } else { hi = mid - 1 }
    }
    let kept = String(chars[0..<lo])

    let keptKB = kept.utf8.count / 1024
    let fullKB = (read.text.utf8.count + 1023) / 1024
    var cut = "cut at 200 KB: the page's text stops at \(keptKB) KB of \(fullKB) KB"
    if dropped > 0 { cut += "; \(dropped) elements left out" }

    var out = read
    out.text = kept
    out.elements = elements
    return (out, cut)
}

/// What remains of the operator's quiet second since their last input; 0 when they have not typed.
public func browserIdleWait(lastInput: Date?, now: Date, quiet: TimeInterval = 1) -> TimeInterval {
    guard let lastInput else { return 0 }
    return max(0, quiet - now.timeIntervalSince(lastInput))
}

// MARK: - The copy

/// Page-written text made safe to quote on one thread line: whitespace (newlines and tabs
/// included) runs collapse to single spaces, `"` becomes `'`, ends trimmed. Done before any trim
/// to length, so a page cannot close the quote or start a line of its own.
public func browserQuotable(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        .replacingOccurrences(of: "\"", with: "'")
}

/// 60 characters at most, the last being `…` when trimmed; an empty label is `the <role> <ref>`.
public func browserElementLabel(_ e: BrowserElement) -> String {
    let label = browserQuotable(e.label)
    if label.isEmpty { return "the \(e.role) \(e.ref)" }
    if label.count > 60 { return String(label.prefix(59)) + "…" }
    return label
}

/// An option's text as quoted in the thread: sanitised, then trimmed like a label.
public func browserOptionLabel(_ option: String) -> String {
    let o = browserQuotable(option)
    return o.count > 60 ? String(o.prefix(59)) + "…" : o
}

public func browserThreadLine(_ act: BrowserPageAct, _ e: BrowserElement) -> String {
    let label = browserElementLabel(e)
    switch act {
    case .click: return "clicked \"\(label)\""
    case .type: return "typed into \"\(label)\""
    case .select(_, let option, _): return "selected \"\(browserOptionLabel(option))\" in \"\(label)\""
    case .press(_, let key): return "pressed \(key.rawValue) in \"\(label)\""
    case .scroll: return "scrolled to \"\(label)\""
    }
}

public func browserStatement(_ act: BrowserPageAct, _ e: BrowserElement, site: String, production: Bool) -> String {
    let label = browserElementLabel(e)
    let base: String
    switch act {
    case .click: base = "click \"\(label)\""
    case .type(_, let text, _): base = "type \"\(text)\" into \"\(label)\""
    case .select(_, let option, _): base = "select \"\(browserOptionLabel(option))\" in \"\(label)\""
    case .press(_, let key): base = "press \(key.rawValue) in \"\(label)\""
    case .scroll: base = "scroll to \"\(label)\""
    }
    return production ? "\(base) on \(site)" : base
}

public func browserReadThreadLine(site: String) -> String {
    "1 page · untrusted text from \(site)"
}
