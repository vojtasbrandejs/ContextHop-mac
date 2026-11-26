import AppKit
import ApplicationServices

/// Hidden debug CLI: `ContextHop --axdump <bundle-id>` prints the Accessibility
/// tree of the target app's focused window and exits — without ever starting
/// NSApplication. Exists to discover WHERE desktop chat apps (Codex Desktop,
/// Claude Desktop) expose the name of the visible conversation, because their
/// window *title* is just the app name (verified via last-detection.json).
enum AXDump {
    static func run(bundleID: String) -> Never {
        print("axdump: AXIsProcessTrusted = \(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            print("axdump: no Accessibility grant for this binary — aborting")
            exit(2)
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = apps.first else {
            print("axdump: no running app with bundle id \(bundleID)")
            exit(3)
        }
        print("axdump: target \(app.localizedName ?? "?") pid=\(app.processIdentifier)")

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        // Chromium/Electron can keep most of its web content out of the AX tree
        // until an assistive client explicitly enables manual accessibility.
        // This is diagnostic-only and mirrors what a screen reader requests.
        let manualResult = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        print("axdump: enable AXManualAccessibility = \(manualResult.rawValue)")
        print("axdump: app attributes=\(copyAttributeNames(appElement).sorted().joined(separator: ","))")

        var windows: [AXUIElement] = []
        if let focused = copyElement(appElement, "AXFocusedWindow") {
            windows.append(focused)
        } else if let main = copyElement(appElement, "AXMainWindow") {
            windows.append(main)
        } else if let list = copyElementArray(appElement, "AXWindows") {
            windows.append(contentsOf: list.prefix(2))
        }
        guard !windows.isEmpty else {
            print("axdump: no focused/main window reachable")
            exit(4)
        }
        for (i, window) in windows.enumerated() {
            print("\n=== window[\(i)] ===")
            // Electron commonly wraps the web area in 10+ anonymous AXGroups.
            // Keep a hard element cap, but search deeply enough to reach it.
            var budget = 1_000
            dump(element: window, depth: 0, maxDepth: 20, budget: &budget)
            if budget <= 0 { print("axdump: element budget exhausted (1000)") }
        }
        exit(0)
    }

    /// One line per element: indent, role, and any of title/value/desc/id/selected.
    private static func dump(element: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int) {
        guard budget > 0 else { return }
        budget -= 1

        let indent = String(repeating: "  ", count: depth)
        let role = copyString(element, "AXRole") ?? "?"
        let subrole = copyString(element, "AXSubrole")
        var parts: [String] = ["\(indent)\(role)\(subrole.map { "/\($0)" } ?? "")"]
        if let t = copyString(element, "AXTitle"), !t.isEmpty { parts.append("title=\(quoted(t))") }
        if let v = copyValueString(element), !v.isEmpty { parts.append("value=\(quoted(v))") }
        if let d = copyString(element, "AXDescription"), !d.isEmpty { parts.append("desc=\(quoted(d))") }
        if let id = copyString(element, "AXIdentifier"), !id.isEmpty { parts.append("id=\(quoted(id))") }
        if let doc = copyString(element, "AXDocument"), !doc.isEmpty { parts.append("doc=\(quoted(doc))") }
        if let url = copyURLString(element, "AXURL"), !url.isEmpty { parts.append("url=\(quoted(url))") }
        if let sel = copyBool(element, "AXSelected"), sel { parts.append("SELECTED") }
        if let focused = copyBool(element, "AXFocused"), focused { parts.append("FOCUSED") }
        print(parts.joined(separator: " "))

        guard depth < maxDepth else { return }
        let children = traversalChildren(element)
        if children.isEmpty {
            let attributes = copyAttributeNames(element)
            if !attributes.isEmpty {
                print("\(indent)  attributes=\(attributes.sorted().joined(separator: ","))")
            }
        }
        for child in children {
            dump(element: child, depth: depth + 1, maxDepth: maxDepth, budget: &budget)
            if budget <= 0 { return }
        }
    }

    // MARK: - AX helpers

    private static func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let ref = copyRaw(element, attribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let ref = copyRaw(element, attribute), let array = ref as? [AnyObject] else { return nil }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    private static func traversalChildren(_ element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for attribute in ["AXSelectedRows", "AXChildren", "AXRows"] {
            for candidate in copyElementArray(element, attribute) ?? []
                where !result.contains(where: { CFEqual($0, candidate) }) {
                result.append(candidate)
            }
        }
        return result
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyRaw(element, attribute) as? String
    }

    private static func copyValueString(_ element: AXUIElement) -> String? {
        guard let ref = copyRaw(element, "AXValue") else { return nil }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copyRaw(element, attribute) as? NSNumber)?.boolValue
    }

    private static func copyURLString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyRaw(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func copyAttributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names else { return [] }
        return (names as? [String]) ?? []
    }

    private static func quoted(_ text: String) -> String {
        let trimmed = text.count > 120 ? String(text.prefix(120)) + "…" : text
        return "\"\(trimmed.replacingOccurrences(of: "\n", with: "\\n"))\""
    }
}
