import ApplicationServices
import Cocoa

let pid = pid_t(Int32(CommandLine.arguments[1])!)
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ name: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return v.map { String(describing: $0) }
}

func walk(_ e: AXUIElement, _ depth: Int) {
    let names = ["AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXHelp"]
    var parts: [String] = []
    for n in names { if let v = attr(e, n), !v.isEmpty { parts.append("\(n)=\(v)") } }
    if !parts.isEmpty { print(String(repeating: "  ", count: depth) + parts.joined(separator: " | ")) }
    var kids: CFTypeRef?
    if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
       let children = kids as? [AXUIElement] {
        for c in children { walk(c, depth + 1) }
    }
}
walk(app, 0)
