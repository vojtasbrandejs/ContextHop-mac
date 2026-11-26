import SwiftUI
import ContextHopKit

/// Prominent action button whose fill is a plain color, so it stays coloured even
/// when the popover window isn't key (the default .borderedProminent greys out
/// while the app is in the background).
private struct SolidActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
    }
}

/// Compact menu-bar popover. Detect-and-copy at the top, an always-on "Recent
/// chats" list below it so the user can pick the right chat by hand when
/// auto-detection has no unique match. Plain Apple look on purpose.
struct PopoverView: View {
    @ObservedObject var state: AppState
    /// Local UI state — not app state, so it resets each time the popover opens.
    @State private var showAllChats = false

    /// Chats shown by default before "Show all" is toggled.
    private static let defaultVisibleCount = 4
    private static let expandedListHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content

            if let error = state.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            recentChatsSection

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 250)
        // NSPopover recycles its content view controller across close/reopen, so
        // @State survives — reset local UI state whenever the shell reopens us.
        .onChange(of: state.popoverOpenToken) { _, _ in
            showAllChats = false
        }
    }

    // MARK: - Main content per phase

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            Button(action: { state.copyLatest() }) {
                Label("Copy context", systemImage: "doc.on.doc")
            }
            .buttonStyle(SolidActionButtonStyle())
            Text(state.candidatesReason ?? "Detects the chat you're looking at.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if state.needsAccessibilityForDetection {
                accessibilityHint
            }

        case .copied(let info):
            copiedBadge(info)
            Text("Now press ⌘V in the target chat.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("← Copy another") { state.copyAnother() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    /// Decentish nudge: without Accessibility, ContextHop can only read WHICH
    /// desktop app is frontmost, not WHICH conversation is open in it — so with
    /// several chats open it always falls back to the picker instead of guessing.
    /// Read-only ask (window titles), never keystrokes — framed that way.
    private var accessibilityHint: some View {
        HStack(spacing: 4) {
            Text("Grant Accessibility to auto-detect the open chat")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Grant…") { state.requestAccessibilityForDetection() }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .font(.caption2)
        }
    }

    /// Shows what was copied, so the user can confirm detection picked the right chat.
    private func copiedBadge(_ info: AppState.CopiedInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Copied").font(.caption).foregroundStyle(.secondary)
            }
            Text(info.conversation)
                .font(.callout).fontWeight(.medium)
                .lineLimit(2).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(info.toolName) · \(info.projectName)")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - Recent chats (always visible)

    /// Sessions shown by default: only the frontmost app's tool, when known —
    /// mixing Codex and Claude chats together isn't what the user wants when
    /// they're clearly looking at one of the two. Unknown frontmost (terminal,
    /// or nothing detected) can't rule either tool out, so show both.
    /// Pure logic lives in `RecentChatsFilter` (ContextHopKit) so it's testable.
    private var defaultToolSessions: [SessionSummary] {
        RecentChatsFilter.defaultSessions(from: state.recentSessions, detectedTool: state.detectedTool)
    }

    private var sectionTitle: String {
        guard let tool = state.detectedTool, !showAllChats else { return "Recent chats" }
        return "Recent \(tool.displayName) chats"
    }

    private var recentChatsSection: some View {
        let defaultSessions = defaultToolSessions
        let showAllButtonVisible = RecentChatsFilter.showAllButtonVisible(
            all: state.recentSessions,
            defaultSessions: defaultSessions,
            defaultVisibleCount: Self.defaultVisibleCount
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sectionTitle)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // "Show all" always spans both tools — it's the escape hatch when
                // the tool-filtered default doesn't have the chat you want, even
                // if that default is short or empty (e.g. frontmost is Codex but
                // only Claude chats exist — those must stay reachable).
                if showAllButtonVisible {
                    Button(showAllChats ? "Show less" : "Show all") {
                        showAllChats.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption2)
                }
            }

            if state.recentSessions.isEmpty {
                Text("No sessions found yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if showAllChats {
                ScrollView {
                    chatRows(state.recentSessions)
                }
                .frame(height: Self.expandedListHeight)
            } else if defaultSessions.isEmpty {
                Text(RecentChatsFilter.emptyStateText(all: state.recentSessions, detectedTool: state.detectedTool))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                chatRows(Array(defaultSessions.prefix(Self.defaultVisibleCount)))
            }
        }
    }

    /// Compact age like "12s", "5m", "3h", "2d", "4w" — a single glyph unit so the
    /// timestamp never steals width from the conversation name.
    static func shortRelative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:            return "\(Int(seconds))s"
        case ..<3_600:         return "\(Int(seconds / 60))m"
        case ..<86_400:        return "\(Int(seconds / 3_600))h"
        case ..<604_800:       return "\(Int(seconds / 86_400))d"
        default:               return "\(Int(seconds / 604_800))w"
        }
    }

    private func chatRows(_ sessions: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions, id: \.filePath) { session in
                Button(action: { state.copy(session) }) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: session.tool == .claudeCode ? "sparkle" : "terminal")
                            .frame(width: 13).foregroundStyle(.secondary)
                        // Conversation name first — several sessions often share
                        // one project, and this list exists to tell chats apart.
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.selectionLabel)
                                .font(.callout).lineLimit(1).truncationMode(.tail)
                            if let project = session.projectName {
                                Text(project)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(Self.shortRelative(session.userRecency))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.tertiary)
        }
    }
}
