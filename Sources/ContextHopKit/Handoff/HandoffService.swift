import Foundation

/// Result of preparing a copy: the prompt that goes to the clipboard.
public struct CopyResult: Sendable {
    public let session: SessionSummary
    public let prompt: String
}

/// Headless copy-flow logic shared by the menu bar app and the debug CLI.
///
/// `prepareCopy` builds the prompt for the clipboard — cheap, pure, repeatable
/// (clicking Copy twice changes nothing). There is no transfer/delta bookkeeping:
/// ContextHop never sees delivery (no auto-paste), so it has no reliable signal to
/// record a sync point off of. Every copy carries the full transcript — the target
/// agent reads what it needs.
/// Putting the prompt on the clipboard is the caller's job (AppKit dependency).
public struct HandoffService: Sendable {
    public let sessionStore: SessionStore
    private let promptBuilder = PromptBuilder()

    public init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
    }

    /// Builds the handoff prompt for a session. No side effects.
    public func prepareCopy(of session: SessionSummary) -> CopyResult {
        let prompt = promptBuilder.buildPrompt(for: session)
        return CopyResult(session: session, prompt: prompt)
    }

    /// Prepare a copy of the most recently active session across both tools.
    public func prepareCopyOfLatestSession() -> CopyResult? {
        guard let latest = sessionStore.recentSessions(limit: 1).first else { return nil }
        return prepareCopy(of: latest)
    }
}

// MARK: - Display helpers (testable formatting used by the UI and CLI)

public extension SessionSummary {
    /// Basename of the project directory, e.g. "/Users/v/Projects/Foo" → "Foo".
    var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// One-line label for session lists: title if the tool provides one,
    /// otherwise the first user message snippet.
    var displayLabel: String {
        title ?? firstUserMessageSnippet ?? "—"
    }

    /// Label used where the user must distinguish rows. A short stable id keeps
    /// otherwise untitled sessions from appearing identical.
    var selectionLabel: String {
        displayLabel == "—" ? "Untitled · \(id.prefix(8))" : displayLabel
    }
}
