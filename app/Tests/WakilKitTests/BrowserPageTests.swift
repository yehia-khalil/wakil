import Foundation
import Testing
@testable import WakilKit

/// The page's shape, its cap and the fixed copy (3c-ii).

private func el(_ ref: String = "e1", role: String = "button", label: String = "Save") -> BrowserElement {
    BrowserElement(ref: ref, role: role, label: label)
}

private func page(text: String, elements: [BrowserElement] = []) -> BrowserPageRead {
    BrowserPageRead(url: "https://example.com", title: "t", text: text, elements: elements, framesSkipped: 0)
}

private func partBytes(_ r: BrowserPageRead) -> Int {
    struct P: Encodable { var text: String; var elements: [BrowserElement] }
    return try! JSONEncoder().encode(P(text: r.text, elements: r.elements)).count
}

@Test func aPageUnderTheCapIsUntouched() {
    let p = page(text: "hello", elements: [el()])
    let out = browserFitToCap(p)
    #expect(out.read == p)
    #expect(out.cut == nil)
}

@Test func aPageOverTheCapSaysWhereItWasCut() {
    let p = page(text: String(repeating: "a", count: 300_000), elements: [el("e1"), el("e2"), el("e3")])
    let out = browserFitToCap(p)
    #expect(partBytes(out.read) <= 204_800)
    #expect(out.read.elements.count == 3)
    let kept = out.read.text.utf8.count / 1024
    #expect(out.cut == "cut at 200 KB: the page's text stops at \(kept) KB of 293 KB")
}

@Test func theCutNeverSplitsACharacter() {
    let unit = "é😀👨‍👩‍👧"
    let text = String(repeating: unit, count: 40_000)
    let p = page(text: text, elements: [el()])
    let out = browserFitToCap(p)
    #expect(out.cut != nil)
    #expect(!out.read.text.unicodeScalars.contains("\u{FFFD}"))
    #expect(text.hasPrefix(out.read.text))
    #expect(partBytes(out.read) <= 204_800)
    #expect(String(data: Data(out.read.text.utf8), encoding: .utf8) == out.read.text)
    // Cut on a grapheme boundary: the kept characters are exactly the original's first characters,
    // so a family emoji is never left as its first half.
    #expect(Array(text.prefix(out.read.text.count)) == Array(out.read.text))
}

@Test func elementsAloneOverTheCapAreDroppedFromTheEnd() {
    let many = (0..<5_000).map { el("e\($0)", label: String(repeating: "x", count: 59)) }
    let p = page(text: "short", elements: many)
    let out = browserFitToCap(p)
    #expect(partBytes(out.read) <= 204_800)
    #expect(out.read.elements.count < many.count)
    #expect(out.read.elements == Array(many.prefix(out.read.elements.count)))
    let n = many.count - out.read.elements.count
    #expect(out.cut?.hasSuffix("; \(n) elements left out") == true)
}

@Test func idleWaitIsWhatRemainsOfTheQuietSecond() {
    let now = Date()
    #expect(browserIdleWait(lastInput: nil, now: now) == 0)
    #expect(abs(browserIdleWait(lastInput: now.addingTimeInterval(-0.3), now: now) - 0.7) < 0.001)
    #expect(browserIdleWait(lastInput: now.addingTimeInterval(-2), now: now) == 0)
}

@Test func labelsAreTrimmedAndNeverEmpty() {
    let long = browserElementLabel(el(label: String(repeating: "a", count: 61)))
    #expect(long.count == 60)
    #expect(long.hasSuffix("…"))
    #expect(browserElementLabel(el(label: String(repeating: "a", count: 60))).count == 60)
    #expect(browserElementLabel(el("e7", label: "")) == "the button e7")
    #expect(browserElementLabel(el("e7", label: "  \n ")) == "the button e7")
}

@Test func threadLinesAndStatementsReadAsTheSpecWrites() {
    let f = el("e2", role: "textbox", label: "Email")
    let b = el("e3", label: "Delete booking")
    #expect(browserThreadLine(.type(ref: "e2", text: "x", expect: f), f) == "typed into \"Email\"")
    #expect(browserThreadLine(.click(ref: "e3"), b) == "clicked \"Delete booking\"")
    #expect(browserThreadLine(.select(ref: "e2", option: "UK", expect: f), f) == "selected \"UK\" in \"Email\"")
    #expect(browserThreadLine(.press(ref: "e2", key: .Return), f) == "pressed Return in \"Email\"")
    #expect(browserThreadLine(.scroll(ref: "e3"), b) == "scrolled to \"Delete booking\"")

    let s = "api.initech.com"
    #expect(browserStatement(.click(ref: "e3"), b, site: s, production: true) == "click \"Delete booking\" on api.initech.com")
    #expect(browserStatement(.click(ref: "e3"), b, site: s, production: false) == "click \"Delete booking\"")
    #expect(browserStatement(.type(ref: "e2", text: "hi", expect: f), f, site: s, production: false) == "type \"hi\" into \"Email\"")
    #expect(browserStatement(.select(ref: "e2", option: "UK", expect: f), f, site: s, production: false) == "select \"UK\" in \"Email\"")
    #expect(browserStatement(.press(ref: "e2", key: .Tab), f, site: s, production: true) == "press Tab in \"Email\" on api.initech.com")
    #expect(browserStatement(.scroll(ref: "e3"), b, site: s, production: false) == "scroll to \"Delete booking\"")
}

@Test func theReadLineNamesTheSite() {
    #expect(browserReadThreadLine(site: "api.initech.dev") == "1 page · untrusted text from api.initech.dev")
}
