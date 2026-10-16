import AppKit
import WebKit

/// `--probe-monaco <directory>`: proves Monaco's diff editor renders inside
/// the built app with the network blocked (3a-i Task 1, a stop gate).
///
/// Runs inside `NSApp.run`, as the ordinary launch does, and ends the process
/// itself with `exit(code)`. Every other way of waiting failed: without an
/// AppKit event loop the window is never visible to WebKit, so the page is
/// hidden and gets no animation frames, and Monaco paints no text (run 6);
/// a run loop spun by hand inside the async main task starves the main
/// queue (run 7) or lets the runtime's main-queue drain return and exit 0
/// (runs 9-10, stack: `swift_task_asyncMainDrainQueue` -> `exit`).
///
/// Like `--bench-surface` it creates `NSApplication.shared` itself. It must
/// not disturb whoever is at the screen: the activation policy is
/// `.accessory`, `activate` is never called, and the window is borderless,
/// click-through and closed right after the snapshot. It sits ON screen, at
/// the bottom-left of the main screen: an occluded window paints no text.
///
/// Writes `monaco-probe.png`, `monaco-probe.log` (page errors and warnings,
/// the layout report at `shown`, the window's occlusion) and `monaco-probe.txt`
/// (`ready_ms=<n> shown_ms=<n> net_blocked=<bool> shown_via=<raf|timeout>`) and exits 0;
/// exits 1 with the reason in the log after a 10 s timeout.
@MainActor
func runProbeMonacoApp(into directory: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = ProbeAppDelegate(directory: directory)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
    exit(1)  // unreachable: the probe exits from its own task
}

@MainActor
private final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    let directory: String
    init(directory: String) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = directory
        Task { @MainActor in exit(await runProbeMonaco(into: directory)) }
    }
}

@MainActor
private func runProbeMonaco(into directory: String) async -> Int32 {
    // The log is appended line by line, so a probe that dies early still
    // says how far it got.
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let logPath = directory + "/monaco-probe.log"
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let logHandle = FileHandle(forWritingAtPath: logPath)
    let start = CFAbsoluteTimeGetCurrent()
    func elapsed() -> Int { Int((CFAbsoluteTimeGetCurrent() - start) * 1000) }
    func log(_ line: String) {
        let text = "t=\(elapsed()) \(line)\n"
        logHandle?.write(Data(text.utf8))
        FileHandle.standardError.write(Data("probe-monaco: \(text)".utf8))
    }
    defer { try? logHandle?.close() }
    log("[host] probe started pid=\(ProcessInfo.processInfo.processIdentifier)")

    let app = NSApplication.shared

    let blocker: WKContentRuleList
    do { blocker = try await MonacoDiffRenderer.compileNetworkBlock() } catch {
        log("[host] return 1: could not compile the network block: \(error)")
        return 1
    }

    // 900x600 from the start: a zero-size web view lays out nothing.
    let size = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
    // `window.wakilProbe` turns on the page's probe-only parts — its network attempt and
    // its animation-frame counter — which a real pane never runs.
    let probeFlag = WKUserScript(
        source: "window.wakilProbe = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    let renderer = MonacoDiffRenderer(blockNetwork: blocker, frame: size, userScripts: [probeFlag])
    window.contentView = renderer.webView
    // On screen and visible: an occluded window paints no Monaco text.
    // Never made key and never activated, so it takes no focus or input.
    window.level = .normal
    window.ignoresMouseEvents = true
    window.alphaValue = 1
    let visible = NSScreen.main?.visibleFrame ?? .zero
    window.setFrameOrigin(NSPoint(x: visible.minX, y: visible.minY))
    window.orderFrontRegardless()

    var readyMs: Int?
    var shownMs: Int?
    var netBlocked: Bool?
    var shownVia = "unknown"
    renderer.onReadyMessage = { readyMs = elapsed() }
    renderer.onShown = { shownMs = elapsed(); shownVia = $0 }
    renderer.onNetProbe = { netBlocked = $0 }
    // Every page diagnostic, plus the host's own view of the window, goes
    // to monaco-probe.log: a blank snapshot needs more than a timing.
    renderer.onLog = { log($0) }
    log("[host] app.isRunning=\(app.isRunning) occlusionVisible=\(window.occlusionState.contains(.visible)) windowFrame=\(window.frame) screen=\(NSScreen.main?.frame ?? .zero)")

    let original = (0..<200).map { "func f\($0)(_ x: Int) -> Int { return x + \($0) }" }
    var modified = original
    for i in stride(from: 5, to: 200, by: 17) { modified[i] = "func f\(i)(_ x: Int) -> Int { return x * \(i) }" }
    modified.removeSubrange(120..<124)
    modified.insert(contentsOf: ["// added", "let added = 1", "let alsoAdded = 2"], at: 60)
    renderer.show(original: original.joined(separator: "\n"),
                  modified: modified.joined(separator: "\n"), language: "swift")

    let deadline = Date().addingTimeInterval(10)
    while (shownMs == nil || netBlocked == nil) && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    log("[host] after wait: occlusionVisible=\(window.occlusionState.contains(.visible)) isVisible=\(window.isVisible) webViewFrame=\(renderer.webView.frame)")
    guard let shownMs, let readyMs else {
        log("[host] return 1: timeout")
        FileHandle.standardError.write(Data("probe-monaco: timed out after 10 s (ready=\(readyMs.map(String.init) ?? "never"), shown=never)\n".utf8))
        return 1
    }
    // `shown` already waits for the diff and two frames; a little more
    // for the compositor before the snapshot.
    try? await Task.sleep(for: .milliseconds(250))

    var png: Data?
    var snapshotDone = false
    renderer.webView.takeSnapshot(with: nil) { image, _ in
        if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        snapshotDone = true
    }
    while !snapshotDone && Date() < deadline.addingTimeInterval(5) {
        try? await Task.sleep(for: .milliseconds(20))
    }
    renderer.tearDown()
    window.close()

    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let png else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("monaco-probe.png"))
        let line = "ready_ms=\(readyMs) shown_ms=\(shownMs) net_blocked=\(netBlocked.map(String.init) ?? "unknown") shown_via=\(shownVia)\n"
        try line.write(toFile: directory + "/monaco-probe.txt", atomically: true, encoding: .utf8)
    } catch {
        log("[host] return 1: could not write results: \(error)")
        return 1
    }
    log("[host] return 0")
    return 0
}
