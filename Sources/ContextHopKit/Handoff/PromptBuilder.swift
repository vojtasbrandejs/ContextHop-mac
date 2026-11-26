import Foundation

/// Builds the short handoff prompt that gets pasted into the target tool.
/// The target agent reads the transcript file itself — no handoff document is
/// generated, and the prompt always points at the full transcript. There is no
/// delta/partial-read mode: without auto-paste ContextHop never sees whether (or
/// when) a prompt was actually delivered, so any "read only what's newer than X"
/// sync point would be a guess that can silently drop content the target never
/// received. A full transcript read is always safe.
public struct PromptBuilder: Sendable {
    public init() {}

    public func buildPrompt(for session: SessionSummary) -> String {
        var lines: [String] = []
        lines.append("Continue the work from a \(session.tool.displayName) conversation.")
        // displayLabel falls back to "—" when there's neither a title nor a
        // usable first-message snippet — that placeholder carries no
        // information, so skip the line entirely rather than paste it in.
        if session.displayLabel != "—" {
            lines.append("Conversation: \(quoted(session.displayLabel))")
        }
        lines.append("Session ID: \(quoted(session.id))")

        var readLine = "Read the transcript at \(quoted(session.filePath.path))"
        if let cwd = session.cwd {
            readLine += " (project cwd: \(quoted(cwd)))"
        }
        readLine += "."
        lines.append(readLine)

        lines.append(
            "Reconstruct the context, briefly summarize where we left off, then continue the work."
        )
        return lines.joined(separator: "\n")
    }

    /// Session titles, identifiers, and paths originate in tool-owned local
    /// stores and may contain quotes or line breaks. JSON string literals keep
    /// that metadata on one prompt line, so it cannot inject extra instructions
    /// into the generated handoff.
    private func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
