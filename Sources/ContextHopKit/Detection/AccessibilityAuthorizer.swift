import ApplicationServices

/// Accessibility (TCC) gate for reading another app's window title — the only
/// way to tell which of several open conversations in a desktop chat app is
/// actually on screen (see `SystemSignalReader`). Read-only: ContextHop never
/// synthesizes keystrokes or otherwise controls other apps.
public enum AccessibilityAuthorizer {
    /// Whether ContextHop is currently trusted for Accessibility.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask the system to prompt for access (also opens the right Settings pane).
    /// The grant lands asynchronously; the user flips the switch in System Settings.
    @discardableResult
    public static func requestAccess() -> Bool {
        // kAXTrustedCheckOptionPrompt is a non-Sendable global under strict
        // concurrency; its documented value is this key string.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
