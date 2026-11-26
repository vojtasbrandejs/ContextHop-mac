import Foundation

/// Facade over both session parsers. All reads are on-demand and read-only.
public struct SessionStore: Sendable {
    public let claudeParser: ClaudeSessionParser
    public let codexParser: CodexSessionParser

    public init(
        claudeParser: ClaudeSessionParser = ClaudeSessionParser(),
        codexParser: CodexSessionParser = CodexSessionParser()
    ) {
        self.claudeParser = claudeParser
        self.codexParser = codexParser
    }

    /// Sessions across both tools (or one, if `tool` is given), sorted by the
    /// latest genuine user message, newest first.
    public func recentSessions(limit: Int = 20, tool: AgentTool? = nil) -> [SessionSummary] {
        var all: [SessionSummary] = []
        if tool == nil || tool == .claudeCode {
            all.append(contentsOf: claudeParser.sessions())
        }
        if tool == nil || tool == .codex {
            all.append(contentsOf: codexParser.sessions())
        }
        // Rank by when the USER last spoke, not by file mtime: a background agent
        // writing to another chat must never outrank the one being typed in.
        all.sort { $0.userRecency > $1.userRecency }
        return Array(all.prefix(limit))
    }

    /// Finds a session by exact id, or by unambiguous id prefix (handy for CLI use).
    public func findSession(id: String) -> SessionSummary? {
        let all = recentSessions(limit: Int.max)
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let prefixMatches = all.filter { $0.id.hasPrefix(id) }
        return prefixMatches.count == 1 ? prefixMatches.first : nil
    }

    /// Full transcript parse for a session — potentially expensive, call on demand.
    public func loadMessages(for session: SessionSummary) throws -> [SessionMessage] {
        switch session.tool {
        case .claudeCode: return try claudeParser.loadMessages(from: session.filePath)
        case .codex: return try codexParser.loadMessages(from: session.filePath)
        }
    }
}
