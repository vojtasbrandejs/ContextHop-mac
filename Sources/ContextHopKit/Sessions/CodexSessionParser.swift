import Foundation

/// Read-only parser for Codex rollout transcripts:
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`.
///
/// Observed structure (undocumented, verified against real files):
/// - `{"type":"session_meta","payload":{"session_id":..., "cwd":..., "originator":..., ...}}`
///   — a single file can contain SEVERAL session_meta lines (each in-place resume appends
///   one); the first one carries the canonical id/cwd.
/// - Resuming a session can ALSO create a brand-new rollout file whose `session_meta`
///   carries the ORIGINAL session's id (the filename UUID differs). A resume chain is
///   therefore one logical session spread over several files; `sessions()` deduplicates
///   by meta session id and keeps the most recently modified file as canonical.
/// - User messages: `{"type":"event_msg","payload":{"type":"user_message","message":"..."}}`
/// - Assistant messages: `{"type":"event_msg","payload":{"type":"agent_message","message":"..."}}`
/// - Plenty of other event/response types (`token_count`, `response_item`, `turn_context`, ...)
///   which are skipped. Unknown types never fail the parse.
///
/// `~/.codex/session_index.jsonl` (`{"id","thread_name","updated_at"}`) provides
/// human-readable titles when present, but is optional.
public struct CodexSessionParser: Sendable {
    public let sessionsDirectory: URL
    public let sessionIndexFile: URL

    private static let quickScanLineLimit = 200

    /// Keeps repeated scans cheap (M2 rescans on every popover open); mtime-invalidated.
    /// Cached summaries carry no title — titles are re-applied from the index each scan.
    private let cache = QuickScanCache()

    public init(sessionsDirectory: URL? = nil, sessionIndexFile: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory
            ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.sessionIndexFile = sessionIndexFile
            ?? home.appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)
    }

    /// One summary per logical session: resume chains (several rollout files sharing
    /// a meta session id) collapse into the file with the newest mtime.
    public func sessions() -> [SessionSummary] {
        let titles = loadTitleIndex()

        var newestById: [String: SessionSummary] = [:]
        for file in rolloutFiles() {
            guard let summary = quickScan(file: file) else { continue }
            if let existing = newestById[summary.id] {
                let canonical = existing.lastActivity >= summary.lastActivity ? existing : summary
                let newestUserMessage = [existing.lastUserMessageAt, summary.lastUserMessageAt]
                    .compactMap { $0 }
                    .max()
                newestById[summary.id] = canonical.withLastUserMessageAt(newestUserMessage)
            } else {
                newestById[summary.id] = summary
            }
        }

        return newestById.values.map { summary in
            guard let title = titles[summary.id] else { return summary }
            return summary.withTitle(title)
        }
    }

    /// Full transcript parse — only call on demand.
    ///
    /// Note for delta/round-trip logic (M5): this returns only `event_msg`
    /// user/agent messages, i.e. the turns actually recorded in THIS file.
    /// A rollout file created by a resume does NOT replay the earlier turns as
    /// event_msg lines (history appears only as `response_item` context), so
    /// messages from before the resume live in the previous file of the chain.
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

    private func rolloutFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            files.append(url)
        }
        return files
    }

    /// Timestamp of the newest `user_message` event among `lines` (scanned back to
    /// front). Injected context blobs (`#`/`/`-prefixed) still count — the user
    /// triggered them, and this only measures *when*, not *what*.
    public static func lastUserMessageTimestamp(inLines lines: [String]) -> Date? {
        for line in lines.reversed() {
            // Cheap pre-filter before paying for JSON parsing.
            guard line.contains("user_message") else { continue }
            guard let object = ParsingSupport.jsonObject(fromLine: line),
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let timestamp = (object["timestamp"] as? String).flatMap(ParsingSupport.parseISO8601)
            else { continue }
            return timestamp
        }
        return nil
    }

    private func quickScan(file: URL) -> SessionSummary? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        let lastActivity = values?.contentModificationDate ?? .distantPast

        if case .hit(let cached) = cache.lookup(path: file.path, mtime: lastActivity) {
            return cached
        }

        var id: String?
        var cwd: String?
        var snippet: String?

        let lines = ParsingSupport.headLines(of: file, maxLines: Self.quickScanLineLimit)
        for line in lines {
            guard let object = ParsingSupport.jsonObject(fromLine: line),
                  let payload = object["payload"] as? [String: Any] else { continue }

            switch object["type"] as? String {
            case "session_meta":
                // First session_meta wins; later ones come from in-place resumes.
                if id == nil { id = payload["session_id"] as? String ?? payload["id"] as? String }
                if cwd == nil { cwd = payload["cwd"] as? String }
            case "event_msg":
                if snippet == nil,
                   payload["type"] as? String == "user_message",
                   let text = payload["message"] as? String,
                   let meaningful = ParsingSupport.meaningfulSnippetText(text) {
                    snippet = ParsingSupport.truncateSnippet(meaningful)
                }
            default:
                break
            }
            if id != nil && cwd != nil && snippet != nil { break }
        }

        // The meta session id is the conversation id (stable across a resume chain).
        // Filename UUID is only a fallback for files with no/broken session_meta.
        let resolvedId = id ?? Self.idFromFilename(file.lastPathComponent)
        guard let sessionId = resolvedId else {
            cache.store(nil, path: file.path, mtime: lastActivity)
            return nil
        }

        // Newest user message, from a bounded tail read: ranks chats by when the
        // HUMAN last spoke instead of by mtime, which a background agent bumps
        // with every token it writes.
        let initialTail = ParsingSupport.tailLines(of: file)
        let lastUserMessageAt = Self.lastUserMessageTimestamp(
            inFile: file,
            initialTail: initialTail
        )

        let summary = SessionSummary(
            tool: .codex,
            id: sessionId,
            cwd: cwd,
            filePath: file,
            lastActivity: lastActivity,
            lastUserMessageAt: lastUserMessageAt,
            firstUserMessageSnippet: snippet
        )
        cache.store(summary, path: file.path, mtime: lastActivity)
        return summary
    }

    /// Expand the tail window only when a long-running agent has pushed the
    /// user's last message beyond the normal 256 KB quick-scan window.
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

    /// `session_index.jsonl` maps session ids to thread names. Missing file is fine.
    /// Junk thread_names (Codex sometimes stores injected first messages like
    /// "/goal ..." verbatim) are filtered out so the snippet fallback applies.
    /// Observed on disk the index is rewritten in place (ids stay unique), but if
    /// a rename ever appends a second entry for an id, the LAST one must win —
    /// the dictionary assignment below guarantees that.
    private func loadTitleIndex() -> [String: String] {
        guard let content = try? String(contentsOf: sessionIndexFile, encoding: .utf8) else { return [:] }
        var titles: [String: String] = [:]
        content.enumerateLines { line, _ in
            guard let object = ParsingSupport.jsonObject(fromLine: line),
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String,
                  let meaningful = ParsingSupport.meaningfulSnippetText(name)
            else { return }
            titles[id] = meaningful
        }
        return titles
    }

    private static func parseMessageLine(_ line: String) -> SessionMessage? {
        guard let object = ParsingSupport.jsonObject(fromLine: line),
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let text = payload["message"] as? String
        else { return nil }

        let role: SessionMessage.Role
        switch payload["type"] as? String {
        case "user_message": role = .user
        case "agent_message": role = .assistant
        default: return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let timestamp = (object["timestamp"] as? String).flatMap(ParsingSupport.parseISO8601)
        return SessionMessage(role: role, text: trimmed, timestamp: timestamp, uuid: nil)
    }

    /// Extracts the trailing UUID from `rollout-2026-06-26T16-02-39-<uuid>.jsonl`.
    /// Public so the test harness can exercise it directly.
    public static func idFromFilename(_ filename: String) -> String? {
        let stem = filename.hasSuffix(".jsonl") ? String(filename.dropLast(6)) : filename
        guard stem.hasPrefix("rollout-") else { return nil }
        // After "rollout-", the timestamp takes 19 characters (YYYY-MM-DDTHH-mm-ss) plus a dash.
        let afterPrefix = stem.dropFirst("rollout-".count)
        guard afterPrefix.count > 20 else { return nil }
        let id = String(afterPrefix.dropFirst(20))
        return id.isEmpty ? nil : id
    }
}
