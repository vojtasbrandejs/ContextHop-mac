import AppKit
import Foundation
import ContextHopKit

/// Observable state behind the popover. Wraps ContextHopKit's headless services;
/// the only AppKit dependency here is the pasteboard.
@MainActor
final class AppState: ObservableObject {
    struct CopiedInfo: Equatable {
        /// Conversation name (title, or first user message) — what the user recognizes.
        let conversation: String
        let toolName: String
        let projectName: String
        let copiedAt: Date
    }

    enum Phase: Equatable {
        case idle
        /// Prompt is on the clipboard; user pastes with ⌘V themselves.
        case copied(CopiedInfo)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?
    /// Set when auto-detection couldn't resolve a single chat (ambiguous or no
    /// signal). Shown as a short hint above the always-on "Recent chats" list
    /// below, rather than a separate picker — one list, not two.
    @Published private(set) var candidatesReason: String?
    /// All recent sessions across both tools, newest first. Always populated so the
    /// popover can show a "Recent chats" picker the user can pick from directly,
    /// whenever auto-detection has no unique match. Limited to 200; the UI shows a
    /// small default slice + a "Show all" toggle.
    @Published private(set) var recentSessions: [SessionSummary] = []
    /// Bumped every time the popover is about to open. NSPopover recycles its
    /// content view controller, so SwiftUI `@State` in PopoverView (e.g. the
    /// "Show all" toggle) survives close/reopen — `.onAppear` alone won't refire.
    /// PopoverView observes this to reset its local UI state on every open.
    @Published private(set) var popoverOpenToken = 0
    /// Tool implied by the frontmost app (Codex/Claude Desktop), if any. Used by
    /// the popover to default "Recent chats" to that tool only — a terminal or
    /// unrelated app (nil) shows both, since either CLI could be running there.
    @Published private(set) var detectedTool: AgentTool?
    /// Whether ContextHop currently holds the Accessibility grant. Without it,
    /// desktop-app window titles can't be read, so Copy can never tell which of
    /// several open conversations is visible and always falls back to a picker.
    @Published private(set) var needsAccessibilityForDetection = !AccessibilityAuthorizer.isTrusted

    private let handoff: HandoffService
    private let signalReader: SystemSignalReading
    /// Shared by popover refresh and Copy so opening the UI and immediately
    /// clicking the button never launches two full filesystem scans.
    private var sessionScan: Task<[SessionSummary], Never>?
    private var pendingDetection: Task<Void, Never>?
    /// App to inspect for detection. Kept current by the shell as the frontmost
    /// external app changes, so Copy detects whatever chat is up now.
    private var activeApp: FrontmostApp?
    /// Signal captured before ContextHop activates its popover. Claude removes
    /// most web content from its AX tree as soon as it goes into the background,
    /// so reading this only when Copy is pressed is already too late.
    private var capturedSignal: DetectionSignal?

    init(
        handoff: HandoffService? = nil,
        signalReader: SystemSignalReading = SystemSignalReader()
    ) {
        self.handoff = handoff ?? Self.defaultHandoff()
        self.signalReader = signalReader
    }

    /// Public screenshots and UI development can point the app at the repository's
    /// synthetic fixtures instead of exposing real conversation names. Normal
    /// launches do not set this variable and use the user's standard stores.
    private static func defaultHandoff() -> HandoffService {
        guard let fixtureRoot = ProcessInfo.processInfo.environment["CONTEXTHOP_FIXTURES_ROOT"],
              !fixtureRoot.isEmpty else {
            return HandoffService()
        }

        let root = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        return HandoffService(sessionStore: SessionStore(
            claudeParser: ClaudeSessionParser(
                projectsDirectory: root.appendingPathComponent("claude/projects", isDirectory: true),
                desktopSessionsDirectory: root.appendingPathComponent("claude/desktop-sessions", isDirectory: true)
            ),
            codexParser: CodexSessionParser(
                sessionsDirectory: root.appendingPathComponent("codex/sessions", isDirectory: true),
                sessionIndexFile: root.appendingPathComponent("codex/session_index.jsonl")
            )
        ))
    }

    /// Refresh the always-on recent-chats list. Runs off the main thread.
    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.loadRecentSessions(forceRefresh: true)
        }
    }

    /// Reuses an in-flight scan. When Copy follows a just-completed popover
    /// refresh, the populated snapshot is fresh enough and no second scan is
    /// needed.
    private func loadRecentSessions(forceRefresh: Bool) async -> [SessionSummary] {
        if let scan = sessionScan {
            return await scan.value
        }
        if !forceRefresh, !recentSessions.isEmpty {
            return recentSessions
        }

        let store = handoff.sessionStore
        let scan = Task.detached(priority: .userInitiated) {
            store.recentSessions(limit: 200)
        }
        sessionScan = scan
        let sessions = await scan.value
        sessionScan = nil
        recentSessions = sessions
        return sessions
    }

    /// The shell keeps this pointed at the current external frontmost app.
    func setActiveApp(_ app: FrontmostApp?) {
        cancelPendingDetection()
        activeApp = app
        capturedSignal = nil
        detectedTool = app.flatMap { AppClassifier.classify(bundleID: $0.bundleID, name: $0.name).toolHint }
    }

    /// Capture while the selected chat is still frontmost, immediately before
    /// opening/activating the ContextHop popover.
    func captureActiveSignal() {
        capturedSignal = signalReader.readSignal(for: activeApp)
    }

    /// Called by the shell right before the popover is shown, so PopoverView can
    /// reset local UI state (e.g. "Show all") that would otherwise persist across
    /// open/close because NSPopover recycles its content view. Also re-checks the
    /// Accessibility grant, since it can change while the popover is closed.
    func popoverWillOpen() {
        cancelPendingDetection()
        errorMessage = nil
        candidatesReason = nil
        popoverOpenToken += 1
        needsAccessibilityForDetection = !AccessibilityAuthorizer.isTrusted
    }

    /// Triggers the system Accessibility prompt (Settings deep link on repeat asks).
    func requestAccessibilityForDetection() {
        AccessibilityAuthorizer.requestAccess()
    }

    // MARK: - Copy (detect)

    /// Big-button action: detect the chat the user is looking at (frontmost app +
    /// working directory) and copy it. A clear match copies straight away; an
    /// ambiguous or undetectable one leaves a hint and lets the user pick from the
    /// always-on "Recent chats" list instead.
    /// The session scan runs off the main thread. The AX signal was captured
    /// before the popover took focus; a detached fallback exists for callers that
    /// invoke Copy without opening the normal menu-bar UI first.
    func copyLatest() {
        cancelPendingDetection()
        errorMessage = nil
        candidatesReason = nil
        let reader = signalReader
        let app = activeApp
        let capturedSignal = capturedSignal
        pendingDetection = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let signalTask = capturedSignal == nil
                ? Task.detached(priority: .userInitiated) { reader.readSignal(for: app) }
                : nil
            let sessions = await self.loadRecentSessions(forceRefresh: false)
            let signal: DetectionSignal
            if let capturedSignal {
                signal = capturedSignal
            } else if let signalTask {
                signal = await signalTask.value
            } else {
                signal = DetectionSignal()
            }
            guard !Task.isCancelled else { return }
            self.pendingDetection = nil
            let result = ActiveChatDetector.match(signal: signal, sessions: sessions)
            Self.logDetectionIfEnabled(signal: signal, result: result)
            self.applyDetection(result)
        }
    }

    func cancelPendingDetection() {
        pendingDetection?.cancel()
        pendingDetection = nil
    }

    /// Opt-in diagnostic for bugs that can only be reproduced in the menu-bar app.
    /// Detection metadata can contain private titles and local paths, so normal
    /// releases never persist it. A user helping diagnose a problem can launch
    /// with CONTEXTHOP_DIAGNOSTICS=1 and remove the resulting file afterwards.
    private nonisolated static func logDetectionIfEnabled(
        signal: DetectionSignal,
        result: DetectionResult
    ) {
        guard ProcessInfo.processInfo.environment["CONTEXTHOP_DIAGNOSTICS"] == "1" else {
            return
        }
        let outcome: String
        switch result {
        case .resolved(let s): outcome = "resolved \(s.tool.displayName) \(s.id) [\(s.title ?? s.firstUserMessageSnippet ?? "-")]"
        case .ambiguous(let c, _): outcome = "ambiguous (\(c.count))"
        case .noSignal(let r): outcome = "noSignal (\(r.count) recent)"
        }
        let entry: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "frontmost": signal.frontmostName ?? "-",
            "toolHint": signal.toolHint?.displayName ?? "-",
            "sessionID": signal.sessionID ?? "-",
            "cwd": signal.cwd ?? "-",
            "windowTitle": signal.conversationTitle ?? "-",
            "outcome": outcome,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextHop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("last-detection.json"))
    }

    private func applyDetection(_ result: DetectionResult) {
        switch result {
        case .resolved(let session):
            copy(session)
        case .ambiguous(_, let signal):
            if let cwd = signal.cwd {
                let place = URL(fileURLWithPath: cwd).lastPathComponent
                candidatesReason = "More than one active chat in \(place) — pick one below."
            } else if let title = signal.conversationTitle,
                      !ActiveChatDetector.isAppNameWindowTitle(
                          title,
                          frontmostName: signal.frontmostName
                      ) {
                candidatesReason = "More than one chat matches the visible title — pick one below."
            } else {
                candidatesReason = "Couldn't identify the selected chat — pick one below."
            }
        case .noSignal(let recent):
            if recent.isEmpty {
                errorMessage = "No sessions found — is Claude Code or Codex installed?"
            } else {
                candidatesReason = "Couldn't auto-detect — pick a chat below."
            }
        }
    }

    /// Copy is a pure, cheap step: build the (always-full) prompt and arm the
    /// clipboard. No bookkeeping — there is no delta/transfer state to record.
    func copy(_ session: SessionSummary) {
        cancelPendingDetection()
        errorMessage = nil
        candidatesReason = nil
        let result = handoff.prepareCopy(of: session)
        setClipboard(result.prompt)
        phase = .copied(CopiedInfo(
            conversation: session.selectionLabel,
            toolName: session.tool.displayName,
            projectName: session.projectName ?? "unknown project",
            copiedAt: Date()
        ))
    }

    /// "← Copy another": discard the current copy and return to detection so the
    /// user can switch windows and copy a different chat.
    func copyAnother() {
        cancelPendingDetection()
        phase = .idle
        errorMessage = nil
        candidatesReason = nil
    }

    func startOver() {
        copyAnother()
    }

    private func setClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
