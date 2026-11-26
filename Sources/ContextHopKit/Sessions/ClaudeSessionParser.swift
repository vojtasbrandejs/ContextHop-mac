import Foundation

/// Read-only parser for Claude Code transcripts: `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`.
///
/// The format is undocumented append-only JSONL. Message lines have `"type": "user"` or
/// `"type": "assistant"` with a nested `message` object; many other line types exist
/// (`queue-operation`, `attachment`, `last-prompt`, `custom-title`, `system`, `mode`,
/// `file-history-snapshot`, `summary`, ...) and new ones appear between versions, so the
/// parser skips anything it does not recognize instead of failing.
public struct ClaudeSessionParser: Sendable {
    public let projectsDirectory: URL
    /// Claude DESKTOP's own session store (outside `~/.claude`):
    /// `~/Library/Application Support/Claude/claude-code-sessions/<ws>/<uuid>/*.json`,
    /// each `{"cliSessionId": <jsonl session uuid>, "title": ..., ...}`. This is
    /// where the conversation names shown in the Claude Desktop UI live. A
    /// transcript may carry no `custom-title` line for a long time and gain one
    /// later (observed live on a real 28 MB session: named only in this store at
    /// first, custom-title lines appended afterwards) — which is why an
    /// in-transcript custom-title, when present, beats this store.
    public let desktopSessionsDirectory: URL

    /// How many head lines a quick scan reads to find cwd and the first user message.
    private static let quickScanLineLimit = 200

    /// Keeps repeated scans cheap (M2 rescans on every popover open); mtime-invalidated.
    /// Cached summaries carry only jsonl-derived titles — desktop titles are
    /// re-applied from the index on every scan (they change independently).
    private let cache = QuickScanCache()

    public init(projectsDirectory: URL? = nil, desktopSessionsDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsDirectory = projectsDirectory
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.desktopSessionsDirectory = desktopSessionsDirectory
            ?? home.appendingPathComponent(
                "Library/Application Support/Claude/claude-code-sessions",
                isDirectory: true
            )
    }

    /// Quick scan of all sessions: id from filename, mtime from the file system,
    /// cwd + first user message from the first ~200 lines. No full transcript parse.
    public func sessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var summaries: [SessionSummary] = []
        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            // Non-recursive listing: subdirectories like `<uuid>/subagents/` hold
            // subagent transcripts and are intentionally ignored.
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if let summary = quickScan(file: file) {
                    summaries.append(summary)
                }
            }
        }

        // Titles: an in-transcript `custom-title` (an explicit rename) wins;
        // otherwise fall back to the Claude Desktop UI name from its own store.
        let desktopTitles = loadDesktopTitleIndex()
        guard !desktopTitles.isEmpty else { return summaries }
        return summaries.map { summary in
            guard summary.title == nil, let title = desktopTitles[summary.id] else { return summary }
            return summary.withTitle(title)
        }
    }

    /// Keeps the desktop-store scan cheap: store files are big (~200 KB each,
    /// they embed full MCP configs) and `sessions()` runs on every popover open.
    /// Unchanged files (same mtime) cost one `resourceValues` stat, no read.
    private let desktopTitleCache = DesktopTitleCache()

    /// Maps jsonl session uuid (`cliSessionId`) → the conversation title shown
    /// in the Claude Desktop UI. Missing directory or malformed files are fine —
    /// the whole store is optional. If several desktop records point at the same
    /// cli session (e.g. after a resume), the most recently modified file wins.
    private func loadDesktopTitleIndex() -> [String: String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: desktopSessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var newest: [String: (title: String, mtime: Date)] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else { continue }
            let mtime = values.contentModificationDate ?? .distantPast

            let record: DesktopTitleRecord?
            switch desktopTitleCache.lookup(path: url.path, mtime: mtime) {
            case .hit(let cached):
                record = cached
            case .miss:
                record = Self.parseDesktopRecord(at: url)
                desktopTitleCache.store(record, path: url.path, mtime: mtime)
            }
            guard let record else { continue }
            if let existing = newest[record.cliSessionId], existing.mtime >= mtime { continue }
            newest[record.cliSessionId] = (record.title, mtime)
        }
        return newest.mapValues { $0.title }
    }

    /// Reads one desktop store file. Nil for anything without a usable
    /// `cliSessionId` + `title` pair — cached as nil so it isn't re-read either.
    private static func parseDesktopRecord(at url: URL) -> DesktopTitleRecord? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cliSessionId = object["cliSessionId"] as? String,
              let title = (object["title"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return DesktopTitleRecord(cliSessionId: cliSessionId, title: title)
    }

    /// Full transcript parse — only call on demand (files can be several MB).
    public func loadMessages(from fileURL: URL) throws -> [SessionMessage] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var messages: [SessionMessage] = []
        content.enumerateLines { line, _ in
            if let message = Self.parseMessageLine(line) {
                messages.append(message)
            }
        }
        return messages
    }

    // MARK: - Internals

    private func quickScan(file: URL) -> SessionSummary? {
        let id = file.deletingPathExtension().lastPathComponent
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        let lastActivity = values?.contentModificationDate ?? .distantPast

        if case .hit(let cached) = cache.lookup(path: file.path, mtime: lastActivity) {
            return cached
        }

        var cwd: String?
        var snippet: String?
        var title: String?
        var sawMessage = false

        let lines = ParsingSupport.headLines(of: file, maxLines: Self.quickScanLineLimit)
        for line in lines {
            guard let object = ParsingSupport.jsonObject(fromLine: line) else { continue }
            let type = object["type"] as? String
            // The user-set conversation name (shown in the Claude Code UI), stored
            // as a `custom-title` line. This is what the user recognizes the chat by.
            // The LAST one seen wins — a rename appends a new line.
            if type == "custom-title", let customTitle = Self.customTitle(from: object) {
                title = customTitle
            }
            guard type == "user" || type == "assistant" else { continue }
            sawMessage = true
            if cwd == nil, let lineCwd = object["cwd"] as? String {
                cwd = lineCwd
            }
            if snippet == nil, type == "user", Self.isRealUserMessage(object),
               let text = Self.extractText(fromMessageObject: object),
               let meaningful = ParsingSupport.meaningfulSnippetText(text) {
                snippet = ParsingSupport.truncateSnippet(meaningful)
            }
            // Keep scanning for a title even after cwd+snippet are found — the
            // custom-title line can appear later in the head window.
        }

        // One bounded tail read serves two purposes:
        //  1. Claude re-appends a `custom-title` line to the END of the transcript
        //     whenever the conversation is (re)named, so the current name usually
        //     lives near EOF — far beyond the head window (real files show the
        //     first custom-title as late as line 3368 of 4738). Last one wins.
        //  2. The newest USER message timestamp, which is how we rank chats by
        //     human attention rather than by background agent output.
        let tail = ParsingSupport.tailLines(of: file)
        if let tailTitle = Self.lastCustomTitle(inLines: tail) {
            title = tailTitle
        }
        let lastUserMessageAt = Self.lastUserMessageTimestamp(
            inFile: file,
            initialTail: tail
        )

        // Files with no message lines at all (e.g. summary-only artifacts) are not sessions.
        let summary: SessionSummary? = sawMessage
            ? SessionSummary(
                tool: .claudeCode,
                id: id,
                cwd: cwd,
                filePath: file,
                lastActivity: lastActivity,
                lastUserMessageAt: lastUserMessageAt,
                firstUserMessageSnippet: snippet,
                title: title
            )
            : nil
        cache.store(summary, path: file.path, mtime: lastActivity)
        return summary
    }

    /// Extracts a non-empty custom title from a `custom-title` line object.
    private static func customTitle(from object: [String: Any]) -> String? {
        guard let title = (object["customTitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty else { return nil }
        return title
    }

    /// The last custom-title among `lines` (scanned back to front), if any.
    private static func lastCustomTitle(inLines lines: [String]) -> String? {
        for line in lines.reversed() {
            // Cheap pre-filter: full JSON parsing of every tail line is wasteful
            // when only a handful are custom-title lines.
            guard line.contains("\"custom-title\"") else { continue }
            guard let object = ParsingSupport.jsonObject(fromLine: line),
                  object["type"] as? String == "custom-title",
                  let title = customTitle(from: object) else { continue }
            return title
        }
        return nil
    }

    /// Timestamp of the newest genuine user message among `lines` (scanned back to
    /// front). Meta lines (slash-command invocations) and sidechain (subagent)
    /// traffic don't count — neither is the human talking.
    public static func lastUserMessageTimestamp(inLines lines: [String]) -> Date? {
        for line in lines.reversed() {
            // Cheap pre-filter before paying for JSON parsing.
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"") else { continue }
            guard let object = ParsingSupport.jsonObject(fromLine: line),
                  object["type"] as? String == "user",
                  isRealUserMessage(object),
                  // Tool results come back as role "user" too; they carry no text
                  // blocks, so requiring text keeps agent plumbing from counting
                  // as human activity (otherwise a busy agent looks like typing).
                  extractText(fromMessageObject: object) != nil,
                  let timestamp = (object["timestamp"] as? String).flatMap(ParsingSupport.parseISO8601)
            else { continue }
            return timestamp
        }
        return nil
    }

    /// Find the newest real user message even after a long background run. A
    /// fixed 256 KB tail often contains only tool results/assistant output, which
    /// would make recency fall back to mtime and recreate the bug this signal is
    /// meant to fix. Expand to a hard 16 MiB cap only when needed.
    private static func lastUserMessageTimestamp(
        inFile file: URL,
        initialTail: [String]
    ) -> Date? {
        if let timestamp = lastUserMessageTimestamp(inLines: initialTail) {
            return timestamp
        }
        let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        for maxBytes in [1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024]
            where fileSize > maxBytes / 4 {
            if let timestamp = lastUserMessageTimestamp(
                inLines: ParsingSupport.tailLines(of: file, maxBytes: maxBytes)
            ) {
                return timestamp
            }
        }
        return nil
    }

    private static func parseMessageLine(_ line: String) -> SessionMessage? {
        guard let object = ParsingSupport.jsonObject(fromLine: line) else { return nil }
        guard let type = object["type"] as? String,
              let role = SessionMessage.Role(rawValue: type) else { return nil }
        // Same filter as the snippet path: meta lines (command invocations) and
        // sidechain (subagent) traffic are not part of the main conversation.
        guard isRealUserMessage(object) else { return nil }
        guard let text = extractText(fromMessageObject: object), !text.isEmpty else { return nil }

        let timestamp = (object["timestamp"] as? String).flatMap(ParsingSupport.parseISO8601)
        return SessionMessage(
            role: role,
            text: text,
            timestamp: timestamp,
            uuid: object["uuid"] as? String
        )
    }

    /// Filters out meta lines and sidechain (subagent) traffic when picking the first user message.
    private static func isRealUserMessage(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true { return false }
        if object["isSidechain"] as? Bool == true { return false }
        return true
    }

    /// `message.content` is either a plain string or an array of blocks
    /// (`text`, `thinking`, `tool_use`, `tool_result`, ...). Only text blocks count.
    private static func extractText(fromMessageObject object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

/// One usable record from a Claude Desktop store file.
struct DesktopTitleRecord: Sendable {
    let cliSessionId: String
    let title: String
}

/// Mtime-keyed cache for desktop store files, same shape as `QuickScanCache`:
/// `hit(nil)` means "parsed before, no usable record" so junk files are not
/// re-read either.
final class DesktopTitleCache: @unchecked Sendable {
    enum Result {
        case miss
        case hit(DesktopTitleRecord?)
    }

    private var storage: [String: (mtime: Date, record: DesktopTitleRecord?)] = [:]
    private let lock = NSLock()

    func lookup(path: String, mtime: Date) -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[path], entry.mtime == mtime else { return .miss }
        return .hit(entry.record)
    }

    func store(_ record: DesktopTitleRecord?, path: String, mtime: Date) {
        lock.lock()
        defer { lock.unlock() }
        storage[path] = (mtime, record)
    }
}
