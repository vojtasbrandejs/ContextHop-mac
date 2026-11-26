import AppKit
import Foundation
import ContextHopKit

// Headless debug CLI for ContextHop. No external argument-parsing dependency —
// the surface is tiny and this keeps the package dependency-free.

let usage = """
usage:
  contexthop-cli sessions [--tool claude|codex] [--limit N]
      List recent sessions across both tools.

  contexthop-cli copy --session-id <id> [--dry-run]
  contexthop-cli copy --latest [--dry-run]
      Build the handoff prompt for a session (--latest picks the most recent
      session across both tools) — always the full transcript, no delta.
      With --dry-run, only prints the prompt; without it, also copies it to
      the clipboard.

  contexthop-cli detect
      Read the live frontmost-app / working-directory signal and show which
      session it resolves to (or the ambiguous/no-signal fallback).
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func parseTool(_ raw: String) throws -> AgentTool {
    switch raw.lowercased() {
    case "claude", "claude-code", "claudecode": return .claudeCode
    case "codex": return .codex
    default: throw CLIError(description: "unknown tool '\(raw)' (expected claude|codex)")
    }
}

func value(after flag: String, in args: [String]) throws -> String? {
    guard let index = args.firstIndex(of: flag) else { return nil }
    guard index + 1 < args.count else {
        throw CLIError(description: "missing value for \(flag)")
    }
    return args[index + 1]
}

// MARK: - sessions

func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func runSessions(args: [String]) throws {
    let tool = try value(after: "--tool", in: args).map(parseTool)
    let limit = try value(after: "--limit", in: args).map { raw -> Int in
        guard let n = Int(raw), n > 0 else {
            throw CLIError(description: "--limit must be a positive integer")
        }
        return n
    } ?? 10

    let store = SessionStore()
    let sessions = store.recentSessions(limit: limit, tool: tool)
    guard !sessions.isEmpty else {
        print("no sessions found")
        return
    }

    print(pad("TOOL", 12) + pad("ID", 14) + pad("PROJECT", 24) + pad("LAST USER", 18) + "SNIPPET / TITLE")
    for session in sessions {
        let shortId = String(session.id.prefix(12))
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
        let description = session.title ?? session.firstUserMessageSnippet ?? "-"
        print(
            pad(session.tool.displayName, 12)
            + pad(shortId, 14)
            + pad(String(project.prefix(22)), 24)
            + pad(formatTimestamp(session.userRecency), 18)
            + String(description.prefix(60))
        )
    }
}

// MARK: - copy

func runCopy(args: [String]) throws {
    let dryRun = args.contains("--dry-run")
    let useLatest = args.contains("--latest")
    let sessionId = try value(after: "--session-id", in: args)

    guard useLatest || sessionId != nil else {
        throw CLIError(description: "copy requires --session-id <id> or --latest")
    }

    let handoff = HandoffService()
    let session: SessionSummary
    if useLatest {
        guard let latest = handoff.sessionStore.recentSessions(limit: 1).first else {
            throw CLIError(description: "no sessions found")
        }
        session = latest
    } else {
        guard let found = handoff.sessionStore.findSession(id: sessionId!) else {
            throw CLIError(description: "session '\(sessionId!)' not found (exact id or unique prefix)")
        }
        session = found
    }

    // Prompt build — the pure step the app runs on Copy. Always the full
    // transcript; there is no delta/transfer bookkeeping.
    let result = handoff.prepareCopy(of: session)

    print("--- session ---")
    print("tool: \(session.tool.displayName)  id: \(session.id)")
    print("file: \(session.filePath.path)")
    if let cwd = session.cwd { print("cwd:  \(cwd)") }
    print("--- prompt ---")
    print(result.prompt)

    if !dryRun {
        // Real copy: put the prompt on the clipboard, like the app does.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.prompt, forType: .string)
        print("--- clipboard ---")
        print("prompt copied to clipboard (\(result.prompt.count) chars)")
    }
}

// MARK: - detect

func runDetect() {
    let signal = SystemSignalReader().readSignal(for: nil)
    print("--- signal ---")
    print("frontmost: \(signal.frontmostName ?? "-")")
    print("toolHint:  \(signal.toolHint?.displayName ?? "-")")
    print("sessionID: \(signal.sessionID ?? "-")")
    print("cwd:       \(signal.cwd ?? "-")")
    print("title:     \(signal.conversationTitle ?? "-")")

    let result = ActiveChatDetector.match(
        signal: signal,
        sessions: SessionStore().recentSessions(limit: 200)
    )
    print("--- result ---")
    switch result {
    case .resolved(let s):
        print("resolved: \(s.tool.displayName) \(s.id)  (\(s.cwd ?? "-"))")
    case .ambiguous(let candidates, _):
        print("ambiguous — \(candidates.count) candidates:")
        for s in candidates { print("  \(s.tool.displayName) \(s.id)  (\(s.cwd ?? "-"))") }
    case .noSignal(let recent):
        print("no signal — picker of \(recent.count) recent sessions")
    }
}

// MARK: - entry point

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "sessions":
        try runSessions(args: Array(arguments.dropFirst()))
    case "copy":
        try runCopy(args: Array(arguments.dropFirst()))
    case "detect":
        runDetect()
    case "help", "--help", "-h", nil:
        print(usage)
    case let unknown?:
        throw CLIError(description: "unknown command '\(unknown)'\n\n\(usage)")
    }
} catch let error as CLIError {
    FileHandle.standardError.write(Data(("error: " + error.description + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
