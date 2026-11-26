# Privacy

ContextHop is a local macOS utility. It has no account system, network client, analytics, advertising, telemetry, cloud service, or update checker. The developer does not receive data from the app.

## Session files

ContextHop reads local session metadata from:

- `~/.claude/projects`
- `~/.codex/sessions`
- `~/Library/Application Support/Claude/claude-code-sessions`
- optional title indexes maintained by Claude and Codex

Those files can contain conversation text, file paths, project names, and other sensitive material. ContextHop opens them read-only. Its normal session list extracts identifiers, titles, working directories, timestamps, and a short first-message snippet. It does not modify, move, or upload the source files.

The target agent—not ContextHop—reads the full transcript after you paste the generated handoff prompt and authorize that work.

## Accessibility

When macOS Accessibility permission is granted, ContextHop reads the focused window and a bounded portion of the visible Accessibility tree to identify the selected conversation. This can expose visible UI text to ContextHop in memory. The app does not retain or transmit that tree and does not synthesize input.

## Clipboard

When you choose a conversation, ContextHop replaces the general clipboard with a plain-text handoff prompt. That prompt contains the local transcript path, session ID, and possibly the conversation title and project path. ContextHop does not keep clipboard history.

Pasting that prompt into a cloud-backed agent asks the agent to read the referenced full transcript. Review the source conversation before transferring secrets, personal data, confidential work, or material you are not authorized to share.

## Storage and deletion

Normal use in version 1.x creates no ContextHop database, preferences, history, logs, login item, or background service. Earlier development builds may have left `transfer-state.json` or `last-detection.json` in the ContextHop Application Support directory; neither is used by version 1.x and both can be deleted.

Diagnostic logging is off by default. If you explicitly launch ContextHop with `CONTEXTHOP_DIAGNOSTICS=1`, it overwrites:

`~/Library/Application Support/ContextHop/last-detection.json`

That file can contain the frontmost app, conversation title, working directory, session ID, and detection result. It never leaves the Mac. Delete the ContextHop Application Support directory when the diagnostic is complete.

Because ContextHop has no account or server, there is no server-side personal data to export or delete.
