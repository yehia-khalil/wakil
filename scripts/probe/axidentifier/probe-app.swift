import SwiftUI

struct ProbeView: View {
    var body: some View {
        VStack(spacing: 3) {
            Button("P1") {}.accessibilityValue("V1.token")                       // AXValue on a button
            Button("P2") {}.accessibilityIdentifier("I2.token")                   // identifier only
            Button("P3") {}.accessibilityLabel("L3.token")                        // label
            Button("P4") {}.accessibilityHint("H4.token")                         // hint
            Button("P5") {}.accessibilityRepresentation { Text("R5.token") }      // representation
            Button("P6") {}.accessibilityInputLabels(["N6.token"])                // input labels
            AKButton(title: "T7.token", ident: "I7.token")                        // AppKit: AXTitle + identifier
            AKButton(title: "", ident: "I8.token")                                // AppKit: identifier, no title
        }.padding(16).frame(width: 300, height: 300)
    }
}

struct AKButton: NSViewRepresentable {
    let title: String; let ident: String
    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.setAccessibilityIdentifier(ident)
        return b
    }
    func updateNSView(_ v: NSButton, context: Context) {}
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AXProbe3"
        window.contentView = NSHostingView(rootView: ProbeView())
        window.makeKeyAndOrderFront(nil)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let d = Delegate(); app.delegate = d; app.run()
