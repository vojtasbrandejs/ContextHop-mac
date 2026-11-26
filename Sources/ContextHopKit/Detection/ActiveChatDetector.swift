import Foundation

/// What we managed to observe about the frontmost chat before matching sessions.
public struct DetectionSignal: Sendable, Equatable {
    /// Tool implied by the frontmost app itself (e.g. Codex Desktop), if any.
    public var toolHint: AgentTool?
    /// Exact transcript session id exposed by the desktop app, when available.
    /// Claude Desktop's focused web area identifies its local record, which maps
    /// directly to the backing Claude Code `cliSessionId`.
    public var sessionID: String?
    /// Working directory read from a terminal/editor window, if available.
    public var cwd: String?
    /// Focused window title of a desktop chat app (Codex/Claude Desktop) —
    /// usually the open conversation's name. Raw, may carry app-name suffixes
    /// or be truncated with an ellipsis.
    public var conversationTitle: String?
    /// Frontmost app label, for diagnostics / the picker header.
    public var frontmostName: String?

    public init(
        toolHint: AgentTool? = nil,
        sessionID: String? = nil,
        cwd: String? = nil,
        conversationTitle: String? = nil,
        frontmostName: String? = nil
    ) {
        self.toolHint = toolHint
        self.sessionID = sessionID
        self.cwd = cwd
        self.conversationTitle = conversationTitle
        self.frontmostName = frontmostName
    }
}

/// Outcome of trying to identify the active chat.
public enum DetectionResult: Sendable, Equatable {
    /// One clear match — copy this without asking.
    case resolved(SessionSummary)
    /// Several plausible sessions — show these as a picker.
    case ambiguous([SessionSummary], signal: DetectionSignal)
    /// No usable signal — fall back to the recent-sessions picker.
    case noSignal([SessionSummary])
}

/// Identity of the app to inspect for a signal. Captured by the caller *before*
/// showing any UI, so an accessory app opening its own popover can't overwrite
/// the real frontmost app.
public struct FrontmostApp: Sendable, Equatable {
    public let bundleID: String?
    public let name: String?
    public let pid: pid_t

    public init(bundleID: String?, name: String?, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// Reads the frontmost-app / working-directory signals from the system. Split
/// out so the matching logic stays pure and testable.
public protocol SystemSignalReading: Sendable {
    /// Reads the signal for a specific app, or the current frontmost when nil.
    func readSignal(for app: FrontmostApp?) -> DetectionSignal
}

/// Identifies which stored session corresponds to the chat the user is looking at.
public struct ActiveChatDetector: Sendable {
    /// Two cwd matches whose activity is within this window are both "current" —
    /// e.g. Claude Code and Codex open in the same directory. Ambiguous → picker.
    public static let ambiguityWindow: TimeInterval = 120

    private let sessionStore: SessionStore
    private let signalReader: SystemSignalReading?

    public init(sessionStore: SessionStore = SessionStore(), signalReader: SystemSignalReading? = nil) {
        self.sessionStore = sessionStore
        self.signalReader = signalReader
    }

    /// Detect the active chat, reading the live system signal and matching it
    /// against recent sessions.
    public func detect(app: FrontmostApp? = nil, pickerLimit: Int = 6) -> DetectionResult {
        let signal = signalReader?.readSignal(for: app) ?? DetectionSignal()
        let sessions = sessionStore.recentSessions(limit: 200)
        return Self.match(signal: signal, sessions: sessions, pickerLimit: pickerLimit)
    }

    /// Pure matcher: given an observed signal and sessions (newest first),
    /// decide on a single session, an ambiguous set, or no signal.
    public static func match(
        signal: DetectionSignal,
        sessions: [SessionSummary],
        pickerLimit: Int = 6
    ) -> DetectionResult {
        let recent = Array(sessions.prefix(pickerLimit))

        // Strongest possible signal: the desktop app exposed the exact backing
        // transcript id. A tool hint scopes the lookup defensively in case two
        // stores ever use the same identifier.
        if let sessionID = signal.sessionID, !sessionID.isEmpty {
            let exact = sessions.filter {
                $0.id == sessionID && (signal.toolHint == nil || $0.tool == signal.toolHint)
            }
            if exact.count == 1, let session = exact.first {
                return .resolved(session)
            }
            if exact.count > 1 {
                return .ambiguous(Array(exact.prefix(pickerLimit)), signal: signal)
            }
            // A stale desktop record must not make us grab an unrelated chat.
            return .noSignal(recent)
        }

        // Strongest signal: a working directory. Match sessions in that directory.
        if let cwd = signal.cwd, !cwd.isEmpty {
            let inDir = sessions
                .filter { cwdMatches($0.cwd, cwd) }
                .sorted { $0.userRecency > $1.userRecency }

            if let newest = inDir.first {
                // A bare folder name (no "/") is a weak signal: different absolute
                // paths can share a last component (~/work/Foo vs ~/personal/Foo).
                // If it matched more than one distinct directory, never auto-pick
                // by recency — ask instead.
                let isBareName = !cwd.contains("/")
                let distinctDirs = Set(inDir.compactMap { $0.cwd?.lowercased() })
                if isBareName && distinctDirs.count > 1 {
                    return .ambiguous(Array(inDir.prefix(pickerLimit)), signal: signal)
                }
                // If the runner-up in the same directory was active at nearly the
                // same time (both tools live there), let the user choose.
                let contenders = inDir.filter {
                    newest.userRecency.timeIntervalSince($0.userRecency) <= ambiguityWindow
                }
                if contenders.count > 1 {
                    return .ambiguous(contenders, signal: signal)
                }
                return .resolved(newest)
            }
            // cwd known but no session there — fall through to hint / picker.
        }

        // Next: a tool hint from a dedicated desktop app (e.g. Codex Desktop).
        if let hint = signal.toolHint {
            let ofTool = sessions
                .filter { $0.tool == hint }
                .sorted { $0.userRecency > $1.userRecency }
            guard let newest = ofTool.first else { return .noSignal(recent) }
            // A single candidate can't pick the wrong conversation.
            if ofTool.count == 1 { return .resolved(newest) }

            // Several conversations of this tool exist on disk. Only the exact
            // VISIBLE title may choose one; recency describes activity, not which
            // sidebar row the user selected.
            if let windowTitle = signal.conversationTitle,
               !isAppNameWindowTitle(windowTitle, frontmostName: signal.frontmostName) {
                let byTitle = sessionsMatching(windowTitle: windowTitle, in: ofTool)
                // byTitle preserves ofTool's newest-first order.
                if byTitle.count == 1, let match = byTitle.first {
                    return .resolved(match)
                }
                if byTitle.count > 1 {
                    return .ambiguous(Array(byTitle.prefix(pickerLimit)), signal: signal)
                }
            }
            // No usable title (no grant, generic app title, or no title match):
            // require a choice instead of silently copying a background chat.
            return .ambiguous(Array(ofTool.prefix(pickerLimit)), signal: signal)
        }

        return .noSignal(recent)
    }

    /// Desktop-app names a focused-window title can degenerate to. When the
    /// observed "conversation title" is one of these (or the frontmost app's own
    /// name), it carries zero information about WHICH conversation is visible.
    /// Verified live: Codex Desktop (ChatGPT.app) titles its window "ChatGPT".
    static let knownDesktopAppNames: Set<String> = [
        "chatgpt", "codex", "claude", "chatgpt desktop", "codex desktop", "claude desktop",
    ]

    /// True when a window title is just the app's name (or empty), not a
    /// conversation name.
    public static func isAppNameWindowTitle(_ title: String, frontmostName: String?) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        if let appName = frontmostName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !appName.isEmpty, normalized == appName {
            return true
        }
        return knownDesktopAppNames.contains(normalized)
    }

    // MARK: - Window-title → session matching (pure)

    /// Sessions whose title matches a desktop-app window title. Case-insensitive.
    /// Handles two window-title quirks:
    /// - app-name suffixes ("My chat — Codex"): the full title is tried first,
    ///   then its dash/pipe-separated segments;
    /// - truncation ("My long conversation…"): an ellipsis-terminated candidate
    ///   prefix-matches session titles.
    /// Exact matches beat prefix matches; several equally good matches are all
    /// returned (caller shows a picker). Empty result means "no title signal".
    public static func sessionsMatching(
        windowTitle: String,
        in sessions: [SessionSummary]
    ) -> [SessionSummary] {
        for candidate in titleCandidates(from: windowTitle) {
            let stripped = strippingEllipsis(candidate)
            let truncated = stripped.count < candidate.count
            guard !stripped.isEmpty else { continue }

            let exact = sessions.filter { normalizedTitle($0) == stripped }
            if !exact.isEmpty { return exact }

            if truncated {
                let prefixed = sessions.filter { normalizedTitle($0)?.hasPrefix(stripped) == true }
                if !prefixed.isEmpty { return prefixed }
            }
        }
        return []
    }

    private static func normalizedTitle(_ session: SessionSummary) -> String? {
        guard let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title.lowercased()
    }

    /// Normalized candidate strings to try, most specific first: the whole title,
    /// then its segments. Only em/en dash and pipe separate segments — a plain
    /// " - " occurs inside real conversation names (same policy as
    /// `WindowTitleParser`).
    private static func titleCandidates(from windowTitle: String) -> [String] {
        let full = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !full.isEmpty else { return [] }

        var candidates = [full]
        var segments = [full]
        for separator in [" — ", " – ", " | "] {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }
        }
        return candidates
    }

    /// Removes a trailing "…" or "..." (how macOS marks a truncated title).
    private static func strippingEllipsis(_ text: String) -> String {
        var result = text
        if result.hasSuffix("…") {
            result = String(result.dropLast())
        } else if result.hasSuffix("...") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Does a session's stored cwd match the directory read from the window?
    /// A full path (has a "/") is compared as a normalized path; a bare name
    /// (e.g. a VS Code title showing only the workspace folder) is matched
    /// against the session cwd's last path component.
    static func cwdMatches(_ sessionCwd: String?, _ signalCwd: String) -> Bool {
        guard let sessionCwd else { return false }
        if signalCwd.contains("/") {
            return sameDirectory(sessionCwd, signalCwd)
        }
        return URL(fileURLWithPath: sessionCwd).lastPathComponent.lowercased()
            == signalCwd.lowercased()
    }

    /// Directory equality tolerant of trailing slashes and path normalization.
    /// macOS is case-insensitive by default, so compare case-insensitively.
    static func sameDirectory(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
                .standardizedFileURL.path
                .lowercased()
        }
        return norm(a) == norm(b)
    }
}
