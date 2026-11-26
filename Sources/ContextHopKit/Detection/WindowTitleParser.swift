import Foundation

/// Extracts a working directory from a terminal/editor window title. Titles are
/// user- and app-configurable, so this is a best-effort heuristic; when it can't
/// be sure it returns nil and detection falls back to the picker.
public enum WindowTitleParser {
    /// Shell/app tokens that must never be mistaken for a project folder.
    private static let denylist: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "node", "tmux",
        "nvim", "vim", "ssh", "login", "python", "python3", "pwsh",
        "vs code", "cursor", "code", "vscodium",
        "terminal", "iterm2", "warp", "ghostty", "kitty", "alacritty", "hyper",
    ]

    /// Returns either a full path (contains "/") or a bare folder name.
    public static func workingDirectory(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 1) An explicit path anywhere in the title. Handles spaces in paths
        //    (e.g. "~/Documents/My Long Project Name — zsh"). Only em/en
        //    dash and pipe are treated as suffix separators — a plain " - " is
        //    left alone because it occurs inside real folder names.
        if let startIndex = pathStartIndex(in: trimmed) {
            var path = String(trimmed[startIndex...])
            for separator in [" — ", " – ", " | "] {
                if let range = path.range(of: separator) {
                    path = String(path[..<range.lowerBound])
                }
            }
            // Strip trailing shell git ornaments: "~/foo (main)", "~/foo git:(main)".
            for marker in [" git:(", " (git", " ("] {
                if let range = path.range(of: marker) {
                    path = String(path[..<range.lowerBound])
                }
            }
            path = path.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                return (path as NSString).expandingTildeInPath
            }
        }

        // 2) Editor pattern "file — Folder — App": the second-to-last segment is
        //    usually the workspace folder (a bare name we can match by basename).
        let parts = trimmed
            .components(separatedBy: " — ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            let candidate = parts[parts.count - 2]
            if isPlausibleFolderName(candidate) { return candidate }
        }
        return nil
    }

    private static func pathStartIndex(in title: String) -> String.Index? {
        let tildeSlash = title.range(of: "~/")?.lowerBound
        let slash = title.firstIndex(of: "/")
        switch (tildeSlash, slash) {
        case let (tilde?, root?): return min(tilde, root)
        case let (tilde?, nil): return tilde
        case let (nil, root?): return root
        default: return nil
        }
    }

    private static func isPlausibleFolderName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else { return false }
        return !denylist.contains(name.lowercased())
    }
}
