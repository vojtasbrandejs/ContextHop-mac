import Foundation

/// The agent tools ContextHop can hand context between.
public enum AgentTool: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// Lightweight description of a session, cheap to build (no full transcript parse).
public struct SessionSummary: Sendable, Equatable {
    public let tool: AgentTool
    public let id: String
    public let cwd: String?
    public let filePath: URL
    /// Last write to the transcript file (mtime). Beware: an agent working in the
    /// background bumps this with every token it writes, so it tracks MACHINE
    /// activity, not the user. Use `userRecency` for "which chat is the user on".
    public let lastActivity: Date
    /// Timestamp of the newest message the USER sent in this session, when known.
    /// This is the honest signal of human attention: a background agent grinding
    /// away for an hour never moves it, while the chat the user just typed into
    /// does. Nil when no user message could be found in the scanned window.
    public let lastUserMessageAt: Date?
    /// First real user message, truncated to ~120 characters.
    public let firstUserMessageSnippet: String?
    /// Number of user+assistant messages, if known (nil for quick scans).
    public let messageCount: Int?
    /// Human-readable title if the tool provides one (Codex thread_name).
    public let title: String?

    /// Ranking key for "which chat is the user most likely looking at": when the
    /// user last spoke, falling back to file mtime when that is unknown.
    public var userRecency: Date { lastUserMessageAt ?? lastActivity }

    public init(
        tool: AgentTool,
        id: String,
        cwd: String?,
        filePath: URL,
        lastActivity: Date,
        lastUserMessageAt: Date? = nil,
        firstUserMessageSnippet: String? = nil,
        messageCount: Int? = nil,
        title: String? = nil
    ) {
        self.tool = tool
        self.id = id
        self.cwd = cwd
        self.filePath = filePath
        self.lastActivity = lastActivity
        self.lastUserMessageAt = lastUserMessageAt
        self.firstUserMessageSnippet = firstUserMessageSnippet
        self.messageCount = messageCount
        self.title = title
    }

    /// Returns the same summary with a title applied. Keeping this copy operation
    /// here prevents parsers from accidentally dropping newer fields when an
    /// external title index is layered onto a cached summary.
    public func withTitle(_ title: String) -> SessionSummary {
        SessionSummary(
            tool: tool,
            id: id,
            cwd: cwd,
            filePath: filePath,
            lastActivity: lastActivity,
            lastUserMessageAt: lastUserMessageAt,
            firstUserMessageSnippet: firstUserMessageSnippet,
            messageCount: messageCount,
            title: title
        )
    }

    /// Returns the same summary with a merged user-recency timestamp.
    /// Codex resume chains can span several rollout files, so the canonical
    /// (newest) file must retain the newest user message found anywhere in the
    /// chain.
    public func withLastUserMessageAt(_ timestamp: Date?) -> SessionSummary {
        SessionSummary(
            tool: tool,
            id: id,
            cwd: cwd,
            filePath: filePath,
            lastActivity: lastActivity,
            lastUserMessageAt: timestamp,
            firstUserMessageSnippet: firstUserMessageSnippet,
            messageCount: messageCount,
            title: title
        )
    }
}

/// A single user or assistant message extracted from a transcript.
public struct SessionMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String
    public let timestamp: Date?
    public let uuid: String?

    public init(role: Role, text: String, timestamp: Date? = nil, uuid: String? = nil) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.uuid = uuid
    }
}

// MARK: - Shared parsing helpers

/// Public so the `contexthop-tests` harness can exercise it directly
/// (executable targets cannot use `@testable import`).
public enum ParsingSupport {
    /// Tolerant ISO8601 parser: handles fractional seconds of any precision and plain timestamps.
    public static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // Fractional seconds with other than 3 digits: Codex index uses 6 (trim),
        // some writers emit 1-2 (pad with zeros). Normalize to milliseconds.
        if let dotRange = string.range(of: ".") {
            let afterDot = string[dotRange.upperBound...]
            if let tzStart = afterDot.firstIndex(where: { !$0.isNumber }) {
                var digits = String(afterDot[..<tzStart].prefix(3))
                while digits.count < 3 { digits.append("0") }
                let rebuilt = String(string[..<dotRange.upperBound]) + digits + String(afterDot[tzStart...])
                return fractional.date(from: rebuilt)
            }
        }
        return nil
    }

    /// Returns useful user text while ignoring injected/command content.
    ///
    /// Both tools prepend machine-generated blocks to some user messages:
    /// Codex Desktop injects `<app-context>...</app-context>` and Claude Code
    /// records slash commands in `<command-message>...</command-message>`.
    /// Strip any complete leading XML-like blocks before deciding whether the
    /// remaining text is human-authored. This preserves a real prompt that
    /// follows injected context instead of discarding the entire message.
    static func meaningfulSnippetText(_ text: String) -> String? {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let tag = leadingTagName(in: remainder) {
            let closing = "</\(tag)>"
            guard let range = remainder.range(
                of: closing,
                options: [.caseInsensitive]
            ) else {
                // An incomplete leading wrapper is machine content or a
                // concurrently-written line. Do not expose its internals.
                return nil
            }
            remainder = String(remainder[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !remainder.isEmpty else { return nil }
        if remainder.hasPrefix("#") || remainder.hasPrefix("/") || remainder.hasPrefix("<") {
            return nil
        }
        return remainder
    }

    /// Tag name when the first non-whitespace character begins an XML-like
    /// wrapper (`<app-context ...>`). Closing/declaration tags do not qualify.
    private static func leadingTagName(in text: String) -> String? {
        guard text.first == "<", text.count > 2 else { return nil }
        let afterOpen = text.dropFirst()
        guard let first = afterOpen.first,
              first != "/",
              first != "!",
              first != "?",
              first.isLetter
        else { return nil }

        let name = afterOpen.prefix { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return name.isEmpty ? nil : String(name)
    }

    static func truncateSnippet(_ text: String, limit: Int = 120) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// Reads up to `maxLines` complete lines from the head of a file, incrementally:
    /// small chunks are read only until enough newlines (or EOF) are seen, so short
    /// scans of large transcripts cost a few KB of I/O, not a fixed big slab.
    static func headLines(
        of url: URL,
        maxLines: Int,
        chunkSize: Int = 16 * 1024,
        maxBytes: Int = 1024 * 1024
    ) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var data = Data()
        var newlineCount = 0
        var reachedEOF = false
        while data.count < maxBytes && newlineCount < maxLines {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                reachedEOF = true
                break
            }
            for byte in chunk where byte == 0x0A { newlineCount += 1 }
            data.append(chunk)
        }
        guard !data.isEmpty else { return [] }

        // Decode what we have; a chunk boundary may split a UTF-8 character, so
        // fall back to trimming up to 3 trailing bytes.
        var text: String?
        for drop in 0...3 {
            if let decoded = String(data: data.dropLast(drop), encoding: .utf8) {
                text = decoded
                break
            }
        }
        guard let text else { return [] }

        var lines = text.components(separatedBy: "\n")
        // Unless we hit EOF, the final element is a possibly-incomplete line — drop it.
        // (When we stopped because of maxLines, prefix() below discards it anyway.)
        if !reachedEOF, !text.hasSuffix("\n") {
            lines.removeLast()
        }
        return Array(lines.prefix(maxLines))
    }

    /// Reads the last `maxBytes` of a file and returns its complete lines.
    /// The first line is dropped when the read started mid-file (it is almost
    /// certainly partial); a trailing partial line (file still being written)
    /// simply fails JSON parsing downstream. One bounded read regardless of
    /// file size — transcripts run to tens of MB.
    static func tailLines(of url: URL, maxBytes: Int = 256 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // When we started mid-file we may have cut a line (and possibly a UTF-8
        // character) in half — skip everything up to the first newline before
        // decoding, so the remainder starts on a clean line boundary.
        var slice = data[data.startIndex...]
        if offset > 0 {
            guard let newline = slice.firstIndex(of: 0x0A) else { return [] }
            slice = slice[slice.index(after: newline)...]
        }
        var text = String(data: Data(slice), encoding: .utf8)
        if text == nil, slice.count > 3 {
            // A concurrent append can leave a torn multi-byte UTF-8 character at
            // EOF; without this fallback the whole tail (and its complete lines)
            // would be discarded. Mirrors the headLines guard.
            text = String(data: Data(slice.dropLast(3)), encoding: .utf8)
        }
        guard let text else { return [] }
        return text.components(separatedBy: "\n")
    }

    static func jsonObject(fromLine line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Quick-scan cache

/// Caches quick-scan results keyed by file path, invalidated by mtime.
/// Transcripts are append-only, so an unchanged mtime means the cached head
/// scan is still valid. Shared by parser value copies (class reference).
final class QuickScanCache: @unchecked Sendable {
    /// `hit` carries the cached summary — nil means "scanned before, not a session"
    /// (e.g. a transcript with no message lines), so it is not re-read either.
    enum Result {
        case miss
        case hit(SessionSummary?)
    }

    private var storage: [String: (mtime: Date, summary: SessionSummary?)] = [:]
    private let lock = NSLock()

    func lookup(path: String, mtime: Date) -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[path], entry.mtime == mtime else { return .miss }
        return .hit(entry.summary)
    }

    func store(_ summary: SessionSummary?, path: String, mtime: Date) {
        lock.lock()
        defer { lock.unlock() }
        storage[path] = (mtime, summary)
    }
}
