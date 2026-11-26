import AppKit
import ApplicationServices

/// Live implementation of `SystemSignalReading`: reads the frontmost app via
/// NSWorkspace, and — for terminals/editors — a working directory via the
/// focused Accessibility window title.
public struct SystemSignalReader: SystemSignalReading {
    private let claudeDesktopSessionsDirectory: URL

    public init(claudeDesktopSessionsDirectory: URL? = nil) {
        self.claudeDesktopSessionsDirectory = claudeDesktopSessionsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Claude/claude-code-sessions",
                isDirectory: true
            )
    }

    /// Reads the signal for `app`, or the current frontmost when nil.
    public func readSignal(for app: FrontmostApp?) -> DetectionSignal {
        let target: FrontmostApp
        if let app {
            target = app
        } else if let front = NSWorkspace.shared.frontmostApplication {
            target = FrontmostApp(bundleID: front.bundleIdentifier, name: front.localizedName, pid: front.processIdentifier)
        } else {
            return DetectionSignal()
        }

        let kind = AppClassifier.classify(bundleID: target.bundleID, name: target.name)
        var signal = DetectionSignal(toolHint: kind.toolHint, frontmostName: target.name)

        if kind.mayExposeWorkingDirectory, let title = focusedWindowTitle(pid: target.pid) {
            signal.cwd = WindowTitleParser.workingDirectory(fromTitle: title)
        }
        // Desktop chat apps SHOULD title their focused window after the open
        // conversation, but verified live both Codex Desktop ("ChatGPT") and
        // Claude Desktop use the bare app name — then the conversation name has
        // to be dug out of the window's AX tree (sidebar selection / web area).
        // No AX permission → nil, and detection falls back to an explicit picker.
        if kind.mayExposeConversationTitle {
            let identity = conversationIdentity(pid: target.pid, appName: target.name)
            signal.conversationTitle = identity.title
            if case .claudeDesktop = kind,
               let localID = identity.claudeDesktopSessionID,
               let record = claudeDesktopRecord(localID: localID) {
                signal.sessionID = record.cliSessionID
                if signal.conversationTitle == nil
                    || ActiveChatDetector.isAppNameWindowTitle(
                        signal.conversationTitle ?? "",
                        frontmostName: target.name
                    ) {
                    signal.conversationTitle = record.title
                }
            }
        }
        return signal
    }

    /// Best-effort identity of the VISIBLE conversation in a desktop chat app.
    /// The AX tree can expose an exact Claude local-session URL or a visible
    /// title in the selected row / main pane. The raw window title remains as a
    /// diagnostic fallback, but the matcher treats generic app names as unusable.
    private func conversationIdentity(
        pid: pid_t,
        appName: String?
    ) -> AXTree.ConversationIdentity {
        guard AXIsProcessTrusted(), let window = focusedWindow(pid: pid) else {
            return AXTree.ConversationIdentity(title: nil, claudeDesktopSessionID: nil)
        }
        let windowTitle = AXTree.string(window, kAXTitleAttribute as String)
        let deep = AXTree.conversationIdentity(inWindow: window, appName: appName)
        if let windowTitle,
           !ActiveChatDetector.isAppNameWindowTitle(windowTitle, frontmostName: appName) {
            return AXTree.ConversationIdentity(
                title: windowTitle,
                claudeDesktopSessionID: deep.claudeDesktopSessionID
            )
        }
        return AXTree.ConversationIdentity(
            title: deep.title ?? windowTitle,
            claudeDesktopSessionID: deep.claudeDesktopSessionID
        )
    }

    private struct ClaudeDesktopRecord {
        let cliSessionID: String
        let title: String?
    }

    /// Maps the `local_<uuid>` from Claude's focused web-area URL to the exact
    /// backing Claude Code transcript. Only the one matching JSON file is read.
    private func claudeDesktopRecord(localID: String) -> ClaudeDesktopRecord? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: claudeDesktopSessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let targetName = "\(localID).json"

        for case let url as URL in enumerator where url.lastPathComponent == targetName {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 10 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cliSessionID = object["cliSessionId"] as? String,
                  !cliSessionID.isEmpty else { return nil }
            let title = (object["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeDesktopRecord(
                cliSessionID: cliSessionID,
                title: title?.isEmpty == false ? title : nil
            )
        }
        return nil
    }

    /// Focused window title via the Accessibility API. Returns nil (silently) if
    /// the permission hasn't been granted — detection then falls back to the picker.
    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted(), let window = focusedWindow(pid: pid) else { return nil }
        return AXTree.string(window, kAXTitleAttribute as String)
    }

    /// The app's focused window element, with a capped messaging timeout so a
    /// busy target app can never hang the caller.
    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        // Chromium/Electron may keep web content out of the tree until an
        // assistive client explicitly opts in. Ignore unsupported/error results.
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        return AXTree.element(appElement, kAXFocusedWindowAttribute as String)
    }
}
