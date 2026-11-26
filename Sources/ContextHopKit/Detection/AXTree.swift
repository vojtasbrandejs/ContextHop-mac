import ApplicationServices
import Foundation

/// Small Accessibility-tree toolkit: typed attribute readers plus a defensive
/// deep search for the name of the VISIBLE conversation inside a desktop chat
/// app's window.
///
/// Why it exists: both Codex Desktop (ChatGPT.app) and Claude Desktop are
/// Electron apps whose focused-window AX title is just the app name (verified
/// live via last-detection.json) — the conversation name lives INSIDE the
/// window: on the selected sidebar row and/or as the web area's document title.
/// Everything here is best-effort: any missing attribute or unexpected shape
/// yields nil, never an error.
enum AXTree {
    /// Hard caps so a pathological tree can't stall detection: Electron trees
    /// are deep, and a long sidebar can contain hundreds of elements.
    private static let maxDepth = 24
    private static let maxElements = 1_200
    /// Wall-clock ceiling for the whole search. The element/depth budgets bound
    /// the CALL count, not their duration — the messaging timeout is set on the
    /// app element and may not propagate to elements copied out of its tree, so
    /// a busy target app could otherwise stretch every AX call.
    private static let searchTimeLimit: TimeInterval = 0.7

    // MARK: - Conversation-title deep search

    struct ConversationIdentity {
        var title: String?
        /// Claude Desktop's own `local_<uuid>` record id, taken from the focused
        /// web area's URL. `SystemSignalReader` maps it to the Claude Code id.
        var claudeDesktopSessionID: String?
    }

    /// Best-effort name of the visible conversation in `window`. Preference:
    /// 1. Claude Desktop's exact local session id from the focused web-area URL;
    /// 2. text of a SELECTED row/item;
    /// 3. the main pane's section-header text (Codex);
    /// 4. an AXWebArea title, when it isn't just the app name.
    ///
    /// Breadth-first traversal is intentional. A depth-first walk exhausts its
    /// budget in Codex's large sidebar before reaching the sibling main pane.
    static func conversationIdentity(inWindow window: AXUIElement, appName: String?) -> ConversationIdentity {
        let deadline = Date().addingTimeInterval(searchTimeLimit)
        var webAreaTitle: String?
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var cursor = 0

        while cursor < queue.count, Date() < deadline {
            let current = queue[cursor]
            cursor += 1
            let element = current.element

            if role(element) == "AXWebArea" {
                if let localID = claudeDesktopSessionID(from: urlString(element, kAXURLAttribute as String)) {
                    return ConversationIdentity(title: webAreaTitle, claudeDesktopSessionID: localID)
                }
                if webAreaTitle == nil,
                   let title = string(element, kAXTitleAttribute as String),
                   isUsableTitle(title, appName: appName) {
                    webAreaTitle = title
                }
            }

            // Chromium-backed lists can expose their active item through
            // AXSelectedRows even when it is absent from AXChildren.
            for selectedRow in elements(element, "AXSelectedRows", limit: maxElements) {
                guard Date() < deadline else { break }
                if let text = displayText(of: selectedRow, deadline: deadline),
                   isUsableTitle(text, appName: appName) {
                    return ConversationIdentity(title: text, claudeDesktopSessionID: nil)
                }
            }

            if bool(element, "AXSelected") == true,
               let text = displayText(of: element, deadline: deadline),
               isUsableTitle(text, appName: appName) {
                return ConversationIdentity(title: text, claudeDesktopSessionID: nil)
            }

            // Codex does not mark the active sidebar button selected, but it
            // repeats the visible chat name in the main pane's section header.
            if subrole(element) == "AXLandmarkMain",
               let title = sectionHeaderTitle(in: element, appName: appName, deadline: deadline) {
                return ConversationIdentity(title: title, claudeDesktopSessionID: nil)
            }

            if current.depth < maxDepth {
                queue.append(contentsOf: children(element, limit: maxElements - queue.count).map {
                    (element: $0, depth: current.depth + 1)
                })
            }
        }

        return ConversationIdentity(title: webAreaTitle, claudeDesktopSessionID: nil)
    }

    /// First usable static text inside the main pane's section header. The
    /// header also contains Back/Forward/sidebar buttons, so button
    /// descriptions are deliberately ignored here.
    private static func sectionHeaderTitle(
        in main: AXUIElement,
        appName: String?,
        deadline: Date
    ) -> String? {
        var queue: [(element: AXUIElement, depth: Int)] = [(main, 0)]
        var cursor = 0
        var header: AXUIElement?

        while cursor < queue.count, Date() < deadline {
            let current = queue[cursor]
            cursor += 1
            if subrole(current.element) == "AXSectionHeader" {
                header = current.element
                break
            }
            guard current.depth < 4 else { continue }
            queue.append(contentsOf: children(current.element, limit: 80 - queue.count).map {
                (element: $0, depth: current.depth + 1)
            })
        }
        guard let header else { return nil }

        queue = [(header, 0)]
        cursor = 0
        while cursor < queue.count, Date() < deadline {
            let current = queue[cursor]
            cursor += 1
            if role(current.element) == "AXStaticText",
               let text = directText(of: current.element),
               isUsableTitle(text, appName: appName) {
                return text
            }
            guard current.depth < 5 else { continue }
            queue.append(contentsOf: children(current.element, limit: 80 - queue.count).map {
                (element: $0, depth: current.depth + 1)
            })
        }
        return nil
    }

    private static func claudeDesktopSessionID(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString) else { return nil }
        let id = url.lastPathComponent
        return id.hasPrefix("local_") ? id : nil
    }

    /// A candidate is usable only when it's a real name, not the app's own.
    private static func isUsableTitle(_ text: String, appName: String?) -> Bool {
        !ActiveChatDetector.isAppNameWindowTitle(text, frontmostName: appName)
    }

    /// Human-visible text of an element: its title/value/description, or the
    /// first static-text descendant's value (rows often carry text one level down).
    private static func displayText(of element: AXUIElement, deadline: Date) -> String? {
        if let direct = directText(of: element) { return direct }
        var budget = 30
        return staticTextDescendantValue(of: element, depth: 0, budget: &budget, deadline: deadline)
    }

    private static func directText(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute as String, kAXValueAttribute as String, kAXDescriptionAttribute as String] {
            if let text = string(element, attribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func staticTextDescendantValue(
        of element: AXUIElement, depth: Int, budget: inout Int, deadline: Date
    ) -> String? {
        guard depth < 5, budget > 0, Date() < deadline else { return nil }
        budget -= 1
        if role(element) == "AXStaticText", let text = directText(of: element) {
            return text
        }
        guard depth + 1 < 5 else { return nil }
        for child in children(element, limit: budget) {
            guard budget > 0, Date() < deadline else { break }
            if let text = staticTextDescendantValue(of: child, depth: depth + 1, budget: &budget, deadline: deadline) {
                return text
            }
        }
        return nil
    }

    // MARK: - Typed attribute readers

    static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let ref = raw(element, attribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func children(_ element: AXUIElement, limit: Int) -> [AXUIElement] {
        guard limit > 0 else { return [] }
        // Most apps use AXChildren. Chromium can expose virtualized list items
        // only through AXSelectedRows/AXRows, so include those collections and
        // prioritize the selected row.
        var result: [AXUIElement] = []
        var seen: Set<AXUIElement> = []
        for attribute in ["AXSelectedRows", kAXChildrenAttribute as String, "AXRows"] {
            for candidate in elements(element, attribute, limit: limit) where seen.insert(candidate).inserted {
                result.append(candidate)
                if result.count == limit { return result }
            }
        }
        return result
    }

    private static func elements(_ element: AXUIElement, _ attribute: String, limit: Int) -> [AXUIElement] {
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit, &values)
        let array: [AnyObject]?
        switch result {
        case .success:
            array = values as? [AnyObject]
        case .notImplemented:
            array = raw(element, attribute) as? [AnyObject]
        default:
            return []
        }
        return (array ?? []).prefix(limit).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    /// Non-empty string value of an attribute (numbers are not coerced).
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let text = raw(element, attribute) as? String, !text.isEmpty else { return nil }
        return text
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (raw(element, attribute) as? NSNumber)?.boolValue
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    static func subrole(_ element: AXUIElement) -> String? {
        string(element, kAXSubroleAttribute as String)
    }

    static func urlString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = raw(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }
}
