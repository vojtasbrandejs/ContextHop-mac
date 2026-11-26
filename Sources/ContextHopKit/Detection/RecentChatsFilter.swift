import Foundation

/// Pure logic behind the popover's "Recent chats" list: which sessions the
/// tool-scoped default view shows, whether "Show all" needs to be offered, and
/// what to say when the default view is empty. Split out from PopoverView so it
/// can be unit tested without SwiftUI/AppKit.
public enum RecentChatsFilter {
    /// Sessions shown before "Show all" is toggled: only the frontmost app's
    /// tool, when known. An unknown frontmost (terminal, or nothing detected)
    /// can't rule either tool out, so all sessions are shown.
    public static func defaultSessions(
        from all: [SessionSummary],
        detectedTool: AgentTool?
    ) -> [SessionSummary] {
        guard let tool = detectedTool else { return all }
        return all.filter { $0.tool == tool }
    }

    /// Whether the "Show all" toggle needs to render. Two independent reasons to
    /// show it: the tool filter is hiding sessions of the *other* tool (even if
    /// the filtered list itself is short, or empty), or the filtered list itself
    /// is longer than the default page size. Without the first condition, a
    /// frontmost tool with zero sessions of its own but sessions of the other
    /// tool would have no way to reach them — the reported bug.
    public static func showAllButtonVisible(
        all: [SessionSummary],
        defaultSessions: [SessionSummary],
        defaultVisibleCount: Int
    ) -> Bool {
        all.count > defaultSessions.count || defaultSessions.count > defaultVisibleCount
    }

    /// Message for when the tool-scoped default view has nothing to show.
    /// Mentions the other tool by name when it actually has sessions, so the
    /// user knows "Show all" will surface something rather than nothing.
    public static func emptyStateText(all: [SessionSummary], detectedTool: AgentTool?) -> String {
        guard let tool = detectedTool else { return "No sessions found yet." }
        if let otherTool = all.first(where: { $0.tool != tool })?.tool {
            return "No \(tool.displayName) chats — tap Show all for \(otherTool.displayName)."
        }
        return "No \(tool.displayName) sessions yet."
    }
}
