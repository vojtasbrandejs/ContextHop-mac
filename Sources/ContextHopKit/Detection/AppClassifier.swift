import Foundation

/// What kind of app is frontmost. The host tells us where a chat *might* be, not
/// which tool for certain: a terminal or editor can run either Claude Code or
/// Codex, so those carry no tool hint — the working directory does the real work.
/// A dedicated desktop app (Codex Desktop) is a strong tool hint on its own.
public enum FrontmostKind: Equatable, Sendable {
    /// Codex's own desktop app — strong hint that the active tool is Codex.
    case codexDesktop
    /// Anthropic's Claude desktop app, which hosts Claude Code sessions — a hint
    /// that the active tool is Claude Code (symmetric to Codex Desktop).
    case claudeDesktop
    /// VS Code / Cursor: hosts the Codex extension and an integrated terminal.
    case editor(String)
    /// A terminal emulator that could be running either CLI.
    case terminal(String)
    /// Anything else.
    case other(String)

    /// A tool this frontmost app implies on its own, if any.
    public var toolHint: AgentTool? {
        switch self {
        case .codexDesktop: return .codex
        case .claudeDesktop: return .claudeCode
        case .editor, .terminal, .other: return nil
        }
    }

    /// Whether this host is expected to expose a working directory we can read
    /// from the focused window title to match against a session.
    public var mayExposeWorkingDirectory: Bool {
        switch self {
        case .terminal, .editor: return true
        case .codexDesktop, .claudeDesktop, .other: return false
        }
    }

    /// Whether this host's window title is expected to carry the conversation
    /// name. Desktop chat apps title their window after the open thread, which
    /// pinpoints the exact session (mtime alone picks the last-written one,
    /// which with several open conversations is often not the visible one).
    public var mayExposeConversationTitle: Bool {
        switch self {
        case .codexDesktop, .claudeDesktop: return true
        case .terminal, .editor, .other: return false
        }
    }
}

/// Pure classification of a frontmost app by bundle id / name. No IO.
public enum AppClassifier {
    /// Known terminal emulators by bundle identifier → display name.
    static let terminalBundleIDs: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "com.mitchellh.ghostty": "Ghostty",
        "net.kovidgoyal.kitty": "kitty",
        "co.zeit.hyper": "Hyper",
        "io.alacritty": "Alacritty",
    ]

    /// Editors that host both a Codex extension and an integrated terminal.
    static let editorBundleIDs: [String: String] = [
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.vscodium": "VSCodium",
    ]

    public static func classify(bundleID: String?, name: String?) -> FrontmostKind {
        let id = bundleID ?? ""
        let lowerName = (name ?? "").lowercased()

        if let terminal = terminalBundleIDs[id] { return .terminal(terminal) }
        if let editor = editorBundleIDs[id] { return .editor(editor) }

        // Bundle ids for the desktop apps aren't stable across builds/channels,
        // so fall back to name matching for those two. Verified live: Codex
        // Desktop currently ships as "ChatGPT.app" with bundle id
        // "com.openai.codex" (matched by id, NOT by name), Claude Desktop as
        // "Claude.app" / "com.anthropic.claudefordesktop".
        // Match Codex specifically — a plain ChatGPT desktop install
        // (com.openai.chat) is NOT Codex and must not claim the hint.
        if id == "com.openai.codex" || id.hasPrefix("com.openai.codex.") || lowerName == "codex" {
            return .codexDesktop
        }
        if lowerName == "claude" || id.contains("com.anthropic") {
            return .claudeDesktop
        }
        // Name-based terminal fallback (bundle id missing or unknown build).
        for known in terminalBundleIDs.values where lowerName == known.lowercased() {
            return .terminal(known)
        }
        return .other(name ?? id)
    }
}
