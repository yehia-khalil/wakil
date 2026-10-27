// axresolve — the e2e harness's accessibility resolver AND actuator.
//
// It answers *where on screen is the element whose `AXIdentifier` is X?*, and
// — since 2026-09-23 — it also presses and sets that element.
//
// **Acting here reverses docs/wakil/agent-e2e-probe.md §4b, deliberately.**
// That section kept all actuation in Orca so there would be one write channel,
// inside the place that reports `unverified (synthetic input)`. Three measured
// facts overturned it:
//
//   - **Orca will not click our fixture at all.** Its coordinate click is
//     refused with `window_not_focused: ... (current: no focused window)`
//     while System Events simultaneously reports that very pid frontmost with
//     a focused window named "Wakil". Measured from inside the click path.
//     `--restore-window`, System Events activation, waiting for the
//     foreground, and Orca's own documented remedy ("run get-app-state again,
//     and retry") were each tried and each refused. A write channel that
//     refuses to write is not a channel.
//   - **The reporting being protected was empty.** Every Orca coordinate
//     click returns `unverified (synthetic input)`, and an AX press returns
//     `accessibility action unasserted`. Both are unverified, so staying
//     inside Orca bought an unverified verdict either way. What actually
//     establishes an act landed is #251's rule — an unverified act must be
//     confirmed by a positive read of the window — and that lives in the
//     runner, not in either tool.
//   - **Setting a value can be verified here and cannot be there.**
//     `orca computer set-value` addresses only by `--element-index`, which
//     #250 ruled out permanently because `get-app-state` emits no identifiers.
//     Acting on the element directly needs no index, and the value can be read
//     back immediately — so `set-value` is the one act this reports as
//     genuinely `verified`, which neither channel could do before.
//
// **Why it exists at all.** `orca computer get-app-state` never emits an
// identifier. Measured 2026-09-23: for a button its compact formatter prints
// `AXTitle` or `AXValue` and nothing else — not `AXIdentifier`, not
// `AXDescription`, not `AXHelp` — and its flag list has no verbosity option.
// The identifiers are on the elements; the snapshot discards them.
//
// **Why not reproduce Orca's element indexes instead.** Its formatter flattens
// the tree and drops container groups — nine drawn controls came back as a
// fourteen-element list with the `AXGroup` wrapper gone. Reproducing that
// numbering would be a second copy of an undocumented rule, agreeing to stay
// in step until it quietly did not. Frames do not have that problem: the
// window frame this reports is byte-identical to the one Orca's own snapshot
// reports, which is what makes the conversion a subtraction.
//
//     axresolve --pid 1234                      # every named element
//     axresolve --pid 1234 --identifier rail.x  # just that one
//     axresolve --pid 1234 --identifier a --drag-to b   # drag a onto b
//
// Output is one JSON object on stdout, always — including for a refusal, so a
// caller never has to parse prose to find out what went wrong.

import ApplicationServices
import Cocoa

// MARK: - The wire shape

struct Element: Encodable {
    let identifier: String
    let role: String
    let enabled: Bool
    /// Screen coordinates, top-left origin — the same space `AXPosition`
    /// reports and the same space Orca's snapshot reports its window in.
    let x, y, width, height: Double
}

struct Window: Encodable {
    let x, y, width, height: Double
}

/// What an act did, when one was asked for.
///
/// `verified` is claimed only when this process READ BACK the state it just
/// wrote. A press cannot be verified that way — AX reports no outcome — so it
/// is reported unverified, with the reason spelled the way Orca spells its
/// own, and the runner's confirmation rule takes it from there.
struct Acted: Encodable {
    let action: String
    let identifier: String
    let verified: Bool
    let reason: String?
}

/// What the window server believed at the moment of an act.
///
/// **The one thing a press cannot tell you about itself.** `AXPress` reports
/// no outcome, so a press that ran and a press that silently did nothing
/// return the same `.success` — and #284 is exactly that shape: `window.send`
/// pressed `ok`, the button was enabled, and no turn started. There is no
/// assertion that separates the two. What can be separated is the state around
/// them, so every act records it and a red run has it to read.
///
/// **Read AFTER the act, not before.** A press that takes the foreground away
/// from the target — a sheet, a palette, another app stealing it mid-press —
/// leaves its trace here and not in a reading taken a moment earlier.
struct Frontmost: Encodable {
    /// The process the window server considers frontmost, and whether it is
    /// the one being driven. A `false` here is the single most useful fact
    /// about a press that did nothing.
    let pid: Int32
    let bundleId: String?
    let isTarget: Bool
    /// Whether the target app has a focused window of its own. An app can be
    /// frontmost with none — behind a locked screen it has no window at all
    /// (#284) — and a press into that state is a press into nothing.
    let targetHasFocusedWindow: Bool
    /// The `AXIdentifier` of whatever holds keyboard focus system-wide, or
    /// nil when it carries none. `do.type` focuses a field and then types, so
    /// a press that followed one should still find that field here; anything
    /// else means focus moved between the two acts.
    let focusedIdentifier: String?
    /// The focused element's role, which is what there is to say when it
    /// carries no identifier — and it usually carries none, because SwiftUI
    /// puts the identifier on a wrapper and the focus on the `AXTextField`
    /// inside it. `AXTextField` and `AXWindow` are different answers to
    /// "where did the keystrokes go", and without this they read alike.
    let focusedRole: String?
    /// The focused element's own identifier, then each ancestor's, nearest
    /// first, up to the window. SwiftUI puts the identifier on a wrapper and
    /// the focus on the field inside it, so a check asking "is focus in the
    /// composer" looks here.
    let focusedWithin: [String]
}

struct Reply: Encodable {
    var ok: Bool
    var pid: Int32?
    var window: Window?
    var elements: [Element]?
    var acted: Acted?
    var frontmost: Frontmost?
    var error: Failure?
}

struct Failure: Encodable {
    let code: String
    let message: String
}

func emit(_ reply: Reply) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(reply)) ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(reply.ok ? 0 : 1)
}

func fail(_ code: String, _ message: String) -> Never {
    emit(Reply(ok: false, error: Failure(code: code, message: message)))
}

// MARK: - Accessibility

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    copyAttribute(element, name) as? String
}

/// Reads what the window server believed, for the act about to be reported.
///
/// **Every field is optional at the source and none of them fails the act.**
/// This is a diagnostic: an act that worked must not be reported as refused
/// because the frontmost application could not be named, and an act that
/// silently did nothing is exactly when these reads are least likely to be
/// tidy. Nil is a fact here, not an error.
func readFrontmost(target: pid_t) -> Frontmost {
    let front = NSWorkspace.shared.frontmostApplication
    let frontPID = front?.processIdentifier ?? -1
    let app = AXUIElementCreateApplication(target)
    let focusedWindow = copyAttribute(app, kAXFocusedWindowAttribute as String) != nil
    // **The TARGET's focused element, not the system's.** The system-wide read
    // answers for whoever is front, so it says nothing whenever the fixture is
    // not — which is exactly the run worth describing. Measured 2026-09-25:
    // straight after `Resolver.Focus` set `AXFocused` on `window.composer` and
    // keystrokes were typed into it, the system-wide attribute reported no
    // element at all, and the act log's most useful column read "nothing".
    var focusedIdentifier: String?
    var focusedRole: String?
    var focusedWithin: [String] = []
    if let element = copyAttribute(app, kAXFocusedUIElementAttribute as String) {
        // `as!` would crash on an attribute that is present and not an
        // element, which a diagnostic must never do.
        if CFGetTypeID(element) == AXUIElementGetTypeID() {
            let focused = element as! AXUIElement
            focusedIdentifier = stringAttribute(focused, kAXIdentifierAttribute as String)
            focusedRole = stringAttribute(focused, kAXRoleAttribute as String)
            var current: AXUIElement? = focused
            for _ in 0..<64 {
                guard let element = current else { break }
                if let identifier = stringAttribute(element, kAXIdentifierAttribute as String),
                    !identifier.isEmpty
                {
                    focusedWithin.append(identifier)
                }
                if stringAttribute(element, kAXRoleAttribute as String) == kAXWindowRole as String {
                    break
                }
                guard let parent = copyAttribute(element, kAXParentAttribute as String),
                    CFGetTypeID(parent) == AXUIElementGetTypeID()
                else { break }
                current = (parent as! AXUIElement)
            }
        }
    }
    return Frontmost(
        pid: frontPID,
        bundleId: front?.bundleIdentifier,
        isTarget: frontPID == target,
        targetHasFocusedWindow: focusedWindow,
        focusedIdentifier: focusedIdentifier,
        focusedRole: focusedRole,
        focusedWithin: focusedWithin)
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let rawPosition = copyAttribute(element, kAXPositionAttribute as String),
        let rawSize = copyAttribute(element, kAXSizeAttribute as String),
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
        AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Walks one window's subtree, collecting every element that carries an
/// identifier.
///
/// **Depth-bounded, and it reports rather than truncates silently.** A cycle
/// in an accessibility tree is not hypothetical, and a resolver that gave up
/// quietly would present as "identifier not found" — the one message that must
/// mean what it says.
func collect(_ element: AXUIElement, depth: Int, into found: inout [Found]) throws {
    if depth > 64 {
        throw ResolveError.tooDeep
    }
    if let identifier = stringAttribute(element, kAXIdentifierAttribute as String),
        !identifier.isEmpty,
        let box = frame(of: element)
    {
        found.append(
            Found(
                described: Element(
                    identifier: identifier,
                    role: stringAttribute(element, kAXRoleAttribute as String) ?? "",
                    enabled: (copyAttribute(element, kAXEnabledAttribute as String) as? Bool) ?? true,
                    x: box.origin.x, y: box.origin.y,
                    width: box.size.width, height: box.size.height),
                live: element))
    }
    if let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children {
            try collect(child, depth: depth + 1, into: &found)
        }
    }
}

/// One element, both as it is reported and as it can be acted on.
struct Found {
    let described: Element
    let live: AXUIElement
}

enum ResolveError: Error { case tooDeep }

// MARK: - Arguments

var pid: pid_t?
var wanted: String?
var press = false
var focus = false
var newValue: String?
/// `--key-down` / `--key-up` name a modifier to post going down or coming up
/// (2d-ii's push-to-talk): the key, and which way it moves.
var modifier: (key: String, down: Bool)?
/// `--drag-to` names the element a drag from `--identifier` is dropped on.
var dragTo: String?
/// `--frontmost` asks for the reading alone, without acting.
///
/// **For the acts this process does not deliver.** The keystroke arms go
/// through Orca, which reports nothing about the window server, and `do.type`
/// — the arm #284's second defect lived in — ends in one of them. The runner
/// asks for this straight afterwards so that step's line in the act log says
/// what every other step's does.
var frontmostOnly = false
var resize: CGSize?
// MARK: - Watching input (#339)

/// `--watch-input` takes no pid and acts on nothing: it installs a listen-only
/// event tap, prints `ready`, and when stdin closes prints every keyboard and
/// pointer event delivered meanwhile, grouped by type and by who posted it.
///
/// **Who posted it is the whole point.** The window server stamps the posting
/// process on every synthetic event (`eventSourceUnixProcessID`); a keyboard or
/// a mouse has none, and reads 0. An idle timer cannot tell these apart — H1,
/// measured 2026-10-09: `HIDIdleTime` fell from 27.6s to 462ms across Orca's
/// own `press Down`, with Orca's helper the only poster this tap saw.
struct SeenInput: Encodable, Hashable {
    let type: String
    let pid: Int32
    let path: String?
}
struct InputReply: Encodable {
    let ok: Bool
    let input: [SeenInputCount]
}
struct SeenInputCount: Encodable {
    let type: String
    let pid: Int32
    let path: String?
    let count: Int
}
let watchedInput: [CGEventType: String] = [
    .keyDown: "keyDown", .keyUp: "keyUp", .flagsChanged: "flagsChanged",
    .mouseMoved: "mouseMoved", .leftMouseDown: "leftMouseDown", .leftMouseUp: "leftMouseUp",
    .rightMouseDown: "rightMouseDown", .rightMouseUp: "rightMouseUp",
    .otherMouseDown: "otherMouseDown", .otherMouseUp: "otherMouseUp",
    .leftMouseDragged: "leftMouseDragged", .rightMouseDragged: "rightMouseDragged",
    .otherMouseDragged: "otherMouseDragged", .scrollWheel: "scrollWheel",
]
var seenInput: [SeenInput: Int] = [:]
var inputTap: CFMachPort?

func posterPath(_ pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func watchInput() -> Never {
    var mask: CGEventMask = 0
    for type in watchedInput.keys { mask |= CGEventMask(1) << CGEventMask(type.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let inputTap { CGEvent.tapEnable(tap: inputTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let name = watchedInput[type] else { return Unmanaged.passUnretained(event) }
        let pid = Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        seenInput[SeenInput(type: name, pid: pid, path: posterPath(pid)), default: 0] += 1
        return Unmanaged.passUnretained(event)
    }
    guard
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: nil)
    else {
        fail(
            "tap_unavailable",
            "no event tap could be installed, so input during an act cannot be watched — "
                + "the process running the harness needs Input Monitoring or Accessibility")
    }
    inputTap = tap
    CFRunLoopAddSource(
        CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    FileHandle.standardOutput.write(Data("ready\n".utf8))

    let main = CFRunLoopGetCurrent()
    var stdinClosed = false
    Thread.detachNewThread {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        stdinClosed = true
        CFRunLoopStop(main)
    }
    while !stdinClosed {
        CFRunLoopRunInMode(.defaultMode, 1, false)
    }
    // Events already posted may still be queued for this tap.
    CFRunLoopRunInMode(.defaultMode, 0.05, false)
    let counts = seenInput.map {
        SeenInputCount(type: $0.key.type, pid: $0.key.pid, path: $0.key.path, count: $0.value)
    }.sorted { ($0.pid, $0.type) < ($1.pid, $1.type) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(InputReply(ok: true, input: counts))) ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "--watch-input" {
    watchInput()
}

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--pid":
        guard let raw = arguments.first, let parsed = Int32(raw) else {
            fail("bad_arguments", "--pid needs a process id")
        }
        arguments.removeFirst()
        pid = parsed
    case "--identifier":
        guard let raw = arguments.first else {
            fail("bad_arguments", "--identifier needs a name")
        }
        arguments.removeFirst()
        wanted = raw
    case "--frontmost":
        frontmostOnly = true
    case "--press":
        press = true
    case "--focus":
        focus = true
    case "--drag-to":
        guard let raw = arguments.first else {
            fail("bad_arguments", "--drag-to needs the identifier to drop on")
        }
        arguments.removeFirst()
        dragTo = raw
    case "--key-down", "--key-up":
        guard let raw = arguments.first else {
            fail("bad_arguments", "\(argument) needs the modifier to post")
        }
        arguments.removeFirst()
        modifier = (raw, argument == "--key-down")
    case "--resize":
        guard let raw = arguments.first else {
            fail("bad_arguments", "--resize needs WIDTHxHEIGHT")
        }
        arguments.removeFirst()
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            fail("bad_arguments", "--resize needs WIDTHxHEIGHT, and \(raw) is not")
        }
        resize = CGSize(width: parts[0], height: parts[1])
    case "--set-value":
        guard let raw = arguments.first else {
            fail("bad_arguments", "--set-value needs the text to set")
        }
        arguments.removeFirst()
        newValue = raw
    default:
        fail("bad_arguments", "unknown argument \(argument)")
    }
}
guard let pid else {
    fail(
        "bad_arguments",
        "usage: axresolve --pid <n> [--identifier <name>] "
            + "[--press | --focus | --set-value <text> | --drag-to <name> | --frontmost | "
            + "--key-down <modifier> | --key-up <modifier> | --resize <W>x<H>]")
}
if [press, focus, newValue != nil, dragTo != nil, frontmostOnly, modifier != nil, resize != nil]
    .filter({ $0 }).count > 1
{
    fail(
        "bad_arguments",
        "--press, --focus, --set-value, --drag-to, --frontmost, --key-down, --key-up and "
            + "--resize are "
            + "different requests; ask for one")
}
if (press || focus || newValue != nil || dragTo != nil) && wanted == nil {
    fail("bad_arguments", "an act needs --identifier naming what to act on")
}

// MARK: - Run

// **The permission check comes first, and says so in its own words.** Without
// it, a revoked or stale Accessibility grant presents as an app with no
// windows and no elements — which reads exactly like "the identifier is not
// there" and sends the reader to the wrong place entirely. This is the failure
// docs/agents already records for Orca itself: the runtime is healthy and
// every call is blocked, and it needs a human toggle rather than debugging.
guard AXIsProcessTrusted() else {
    fail(
        "accessibility_denied",
        "this process is not trusted for Accessibility, so it cannot read any app's "
            + "elements. Grant the terminal running it Accessibility in System Settings › "
            + "Privacy & Security › Accessibility. A revoked grant looks identical to an "
            + "empty tree, which is why this is checked before anything is read.")
}

// **`--frontmost` answers before a window is required, deliberately.** An app
// that presents none is precisely the state this reading exists to name — a
// locked screen leaves the fixture running, frontmost and windowless (#284) —
// and refusing here would turn the diagnostic into the same `no_window` the
// reader is already holding.
if frontmostOnly {
    emit(Reply(ok: true, pid: pid, frontmost: readFrontmost(target: pid)))
}

let app = AXUIElementCreateApplication(pid)
// **The first window that is a window, not the first entry.** A tooltip is an
// `AXHelpTag` in the app's window list, and it comes FIRST. AppKit shows one
// whenever the pointer rests on a control with help text, and the pointer
// does not move during a run. So a layout that puts such a control under it
// (3c-i-narrow's resize, measured 2026-10-26, pointer at 551,818) leaves the
// tooltip in front for about fifty seconds. For that long, a resolver reading
// `windows.first` finds zero identifiers and every check reads "not found".
guard let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement],
    let window = windows.first(where: {
        stringAttribute($0, kAXRoleAttribute as String) == kAXWindowRole as String
    })
else {
    fail(
        "no_window",
        "pid \(pid) presents no accessibility window. It may have exited, or it may not "
            + "have drawn one yet.")
}

// **A resize, which is aimed at the window and not at an element**, so it needs
// no `--identifier`. It runs before the tree is read, so the reply describes
// the window as it now is. **Read back**, because a window with a minimum or
// maximum size clamps without returning an error, and a check that asked for a
// narrow window and got a wide one would assert the wide layout.
var acted: Acted?
if var size = resize {
    guard let value = AXValueCreate(.cgSize, &size) else {
        fail("resize_failed", "a size value could not be created")
    }
    let status = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    guard status == .success else {
        fail("resize_failed", "resizing the window returned AXError \(status.rawValue)")
    }
    guard let after = frame(of: window),
        abs(after.width - size.width) < 1, abs(after.height - size.height) < 1
    else {
        let got = frame(of: window).map { "\(Int($0.width))×\(Int($0.height))" } ?? "no size"
        fail(
            "resize_not_applied",
            "asked for \(Int(size.width))×\(Int(size.height)) and the window is \(got) — "
                + "it has a minimum or maximum size; ask for one inside it")
    }
    acted = Acted(action: "resize", identifier: "window", verified: true, reason: nil)
}

// **Windows only, never the application element.** The system menu bar hangs
// off the application and is full of AXIdentifiers that belong to macOS —
// `_aboutThisMacRequested:` and its forty siblings. None of them is ours, and
// collecting them would put the harness one typo away from driving Shut Down.
var found: [Found] = []
do {
    try collect(window, depth: 0, into: &found)
} catch {
    fail("tree_too_deep", "the accessibility tree is deeper than 64 levels; refusing to guess")
}

// **The drop target is picked out before the filter below discards it.** A
// drag is about two elements, and the reply lists only the one it starts
// from, as every other act's does.
let dropTargets = dragTo.map { name in found.filter { $0.described.identifier == name } }

if let wanted {
    found = found.filter { $0.described.identifier == wanted }
}

guard let windowFrame = frame(of: window) else {
    fail("no_window_frame", "the window reports no position or size, so nothing can be located")
}

// MARK: - Acting

// **A modifier, which is aimed at the app and not at an element.** It is the
// only act with no `--identifier`: a key event goes to the frontmost
// application's key window, and that is the whole of its address. Posted as a
// `flagsChanged` through the HID event tap — the path a keyboard's own ⌥
// takes — and NOT to the pid: an event posted to a process skips the window
// server's routing and arrives with no window, and the composer bar ignores
// any event that is not its own key window's (ComposerBar's monitor).
//
// **The fixture is brought forward first**, for the drag's reason: whatever
// is frontmost receives the event.
//
// **Unverified.** Nothing in the accessibility tree says a modifier is down,
// so this reports no outcome and the runner's rule — an unverified act must
// be confirmed by a later positive read — is what establishes it landed.
//
// **A key posted down stays down for the session until one is posted up**,
// which is why `ParseChecks` refuses a check whose holds are not each
// released later in the same file.
let modifierKeys: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
    "option": (58, .maskAlternate),
    "shift": (56, .maskShift),
    "control": (59, .maskControl),
    "command": (55, .maskCommand),
]
if let modifier {
    guard let key = modifierKeys[modifier.key] else {
        fail(
            "bad_arguments",
            "\(modifier.key) is not a modifier this resolver posts — expected one of "
                + modifierKeys.keys.sorted().joined(separator: ", "))
    }
    // **Frontmost is not enough: the window has to be key** (#2). The composer listens for ⌥
    // only in its key window, and an app made frontmost has none for a moment after — a hold
    // posted then is dropped, and the check's next read finds nothing heard.
    func ready() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && copyAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as String) != nil
    }
    if !ready() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let deadline = Date().addingTimeInterval(1)
        while !ready(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    guard
        let event = CGEvent(
            keyboardEventSource: nil, virtualKey: key.code, keyDown: modifier.down)
    else {
        fail("key_failed", "a \(modifier.key) key event could not be created")
    }
    event.type = .flagsChanged
    event.flags = modifier.down ? key.flag : []
    event.post(tap: .cghidEventTap)
    acted = Acted(
        action: modifier.down ? "key-down" : "key-up", identifier: modifier.key,
        verified: false, reason: "synthetic_input")
}

/// The one element an act is about.
///
/// **Zero and several are both refusals, never a guess.** An identifier that
/// matches nothing may be a renamed control, a screen that never opened or a
/// stale grant; one that matches twice means this cannot tell which control it
/// is about to drive. Acting on either is how a check comes to pass on
/// something that never happened.
func theOne(_ found: [Found], _ identifier: String) -> Found {
    switch found.count {
    case 1:
        return found[0]
    case 0:
        fail("not_found", "\(identifier) matched no element, so there is nothing to act on")
    default:
        fail(
            "ambiguous",
            "\(identifier) matched \(found.count) elements, so this cannot tell which one the "
                + "act is about; give the control a name that includes what distinguishes it")
    }
}

if press {
    let target = theOne(found, wanted!)
    guard target.described.enabled else {
        fail(
            "disabled",
            "\(wanted!) is disabled, so pressing it would do nothing and the check would pass "
                + "on an act that never happened")
    }
    let status = AXUIElementPerformAction(target.live, kAXPressAction as CFString)
    guard status == .success else {
        fail("press_failed", "pressing \(wanted!) returned AXError \(status.rawValue)")
    }
    // **Not verified, and said so.** AX reports no outcome for a press, which
    // is the same thing Orca means by `accessibility action unasserted`.
    acted = Acted(
        action: "press", identifier: wanted!, verified: false,
        reason: "accessibility_action_unasserted")
}

// **Focus, which is a different act from pressing.** A text field refuses
// `AXPress` outright — AXError -25206, action unsupported — and setting its
// value moves no focus and, behind SwiftUI, is not seen by the binding at all.
// A coordinate click would focus it, but Orca refuses one unless the target
// window is the focused topmost recipient, which a fixture window launched by
// `open -n` is not. `AXFocused` is the one route that needs neither.
if focus {
    let target = theOne(found, wanted!)
    guard target.described.enabled else {
        fail("disabled", "\(wanted!) is disabled, so it cannot take focus")
    }
    var settable: DarwinBoolean = false
    guard
        AXUIElementIsAttributeSettable(target.live, kAXFocusedAttribute as CFString, &settable)
            == .success, settable.boolValue
    else {
        fail(
            "not_focusable",
            "\(wanted!) does not accept focus, so asking for it would silently do nothing and "
                + "every keystroke after this would go wherever focus already was")
    }
    let status = AXUIElementSetAttributeValue(
        target.live, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard status == .success else {
        fail("focus_failed", "focusing \(wanted!) returned AXError \(status.rawValue)")
    }
    // **Verified, unlike a press.** AX reports no outcome for a press, but
    // focus is state, and state can be read back.
    let focused = copyAttribute(target.live, kAXFocusedAttribute as String) as? Bool ?? false
    guard focused else {
        fail(
            "focus_refused",
            "\(wanted!) accepted the focus attribute and did not take focus, so every keystroke "
                + "after this would go somewhere else")
    }
    acted = Acted(action: "focus", identifier: wanted!, verified: true, reason: nil)
}

if let newValue {
    let target = theOne(found, wanted!)
    guard target.described.enabled else {
        fail("disabled", "\(wanted!) is disabled, so its value cannot be set")
    }
    var settable: DarwinBoolean = false
    guard
        AXUIElementIsAttributeSettable(target.live, kAXValueAttribute as CFString, &settable)
            == .success, settable.boolValue
    else {
        fail(
            "not_settable",
            "\(wanted!) does not accept a value, so setting one would silently do nothing")
    }
    let status = AXUIElementSetAttributeValue(
        target.live, kAXValueAttribute as CFString, newValue as CFTypeRef)
    guard status == .success else {
        fail("set_failed", "setting \(wanted!) returned AXError \(status.rawValue)")
    }
    // **Read back, because here it can be.** This is the one act either
    // channel can report as genuinely verified rather than merely attempted.
    let readBack = stringAttribute(target.live, kAXValueAttribute as String)
    if readBack != newValue {
        fail(
            "set_not_applied",
            "\(wanted!) was set to \(newValue) but reads back as "
                + "\(readBack ?? "nothing") — the write was accepted and did not stick")
    }
    acted = Acted(action: "set-value", identifier: wanted!, verified: true, reason: nil)
}

// **A drag, which no accessibility action performs.** There is no AXDrag, so
// this is the one act posted as pointer events — and the sequence is the one
// 2c-iv's Task 1 measured, not a guess
// (docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md,
// "the measurements"): a `mouseMoved` to the source's centre and 50 ms, then
// `leftMouseDown` with no hold after it, then twenty `leftMouseDragged` 10 ms
// apart along the straight line, then — since Ruling 12, below — a short rest
// at the target, then `leftMouseUp` at the target's centre. "No hold" is about
// the moment after mouse-down; the rest is at the far end. Without the rest it
// dropped nine of nine in Task 1, and 26 of 30 check runs later; ten steps
// dropped eleven of fifteen, and a hold after
// mouse-down did not help — the step size did (~98pt jumps failed about a
// third of the time, ~49pt ones never). So a longer drag takes more steps,
// never bigger ones: the count is twenty or one per 50pt, whichever is more.
//
// **Unverified, and never retried.** A failed synthetic drag is a session that
// never reached the target — nothing drops and nothing says so — so, like a
// press, this reports no outcome, and the runner's rule that an unverified act
// must be confirmed by a later positive read is what establishes it landed.
if let dragTo {
    let source = theOne(found, wanted!)
    let target = theOne(dropTargets ?? [], dragTo)
    guard source.described.enabled else {
        fail(
            "disabled",
            "\(wanted!) is disabled, so dragging it would do nothing and the check would pass "
                + "on an act that never happened")
    }
    // AX frames and CGEvent positions are the same space: global display
    // coordinates, top-left origin.
    func centre(_ element: Element) -> CGPoint {
        CGPoint(x: element.x + element.width / 2, y: element.y + element.height / 2)
    }
    let start = centre(source.described)
    let end = centre(target.described)

    // **The fixture is brought forward first**, as it was for every measured
    // run: pointer events go to whatever window is under the point, and a
    // window laid over the fixture's would take the drag.
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let deadline = Date().addingTimeInterval(1)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
            Date() < deadline
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func post(_ type: CGEventType, _ at: CGPoint) {
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: at,
                mouseButton: .left)
        else {
            fail("drag_failed", "a \(type.rawValue) mouse event could not be created")
        }
        event.post(tap: .cghidEventTap)
    }
    let distance = hypot(end.x - start.x, end.y - start.y)
    let steps = max(20, Int((distance / 50).rounded(.up)))

    post(.mouseMoved, start)
    usleep(50_000)
    post(.leftMouseDown, start)
    for step in 1...steps {
        usleep(10_000)
        let t = CGFloat(step) / CGFloat(steps)
        post(
            .leftMouseDragged,
            CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
    }
    // **The drag ends at rest on the target, the way a hand ends one** (2c-iv,
    // Ruling 12). The last step above already reaches `end`; what the first
    // sequence lacked was TIME there — its `leftMouseUp` followed the last
    // `leftMouseDragged` at once, and AppKit's drag session sometimes had not
    // yet seen the pointer over the destination: the pane drew its drop
    // outline and the drop was never performed. Measured over the three drag
    // checks, ten runs of each (a run passes only if every drag in it
    // dropped; api-bind and api-unbind drag twice, api-bound-locks once):
    //
    //   end of the drag                              bind   unbind  locks
    //   mouse-up at once (Task 1's sequence)         9/10   9/10    8/10
    //   10 ms, then mouse-up                         10/10  10/10   10/10
    //   one more drag at the target, 10 ms, up       10/10  10/10   10/10
    //   three more drags at the target, 10 ms, up    10/10  10/10   10/10
    //
    // One extra event is the smallest dwell of this shape that measured
    // 10/10, so it is what ships: 20 ms at rest on the target.
    let dwell = 1
    for _ in 0..<dwell {
        usleep(10_000)
        post(.leftMouseDragged, end)
    }
    usleep(10_000)
    post(.leftMouseUp, end)

    acted = Acted(action: "drag", identifier: wanted!, verified: false, reason: "synthetic_input")
}

// **Read only when an act was made, and only after it.** A bare resolution
// answers where an element is and drives nothing, so there is no moment for
// this to describe; recording it anyway would put a reading in the evidence
// that no act is responsible for. See Frontmost.
emit(
    Reply(
        ok: true, pid: pid,
        window: Window(
            x: windowFrame.origin.x, y: windowFrame.origin.y,
            width: windowFrame.size.width, height: windowFrame.size.height),
        elements: found.map { $0.described },
        acted: acted,
        frontmost: acted == nil ? nil : readFrontmost(target: pid)))
