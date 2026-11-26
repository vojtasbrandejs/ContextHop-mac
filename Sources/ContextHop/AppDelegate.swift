import AppKit
import SwiftUI
import ContextHopKit

/// Menu bar shell: status item + transient popover hosting the SwiftUI content.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let state = AppState()
    private weak var observedPopoverWindow: NSWindow?
    /// The last app that was frontmost before ContextHop's popover took focus.
    /// Tracked continuously so detection inspects the real target, not ourselves.
    private var lastExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right",
                accessibilityDescription: "ContextHop"
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("ContextHop")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Transient: closes on click-outside / app switch, like a normal menu bar
        // popover. Flow is Copy → close → switch to target chat → ⌘V (by hand);
        // AppState keeps the copied state across open/close.
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = FirstMousePopoverController(rootView: PopoverView(state: state))

        // Remember whichever external app is frontmost, so a later Copy inspects it.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        state.refresh()
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Ignore our own activation (e.g. when the popover takes focus).
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        lastExternalApp = app
        // Keep the (possibly open) popover pointed at the chat now in front —
        // used by detection to know which app/window the user is looking at.
        state.setActiveApp(FrontmostApp(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier))
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            stopObservingPopoverResize()
            popover.performClose(sender)
        } else {
            // Snapshot the target app BEFORE showing the popover, in case showing
            // it activates us. Prefer the current frontmost if it isn't us.
            let front = NSWorkspace.shared.frontmostApplication
            if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
                lastExternalApp = front
            }
            state.setActiveApp(lastExternalApp.map {
                FrontmostApp(bundleID: $0.bundleIdentifier, name: $0.localizedName, pid: $0.processIdentifier)
            })
            // Read the selected chat NOW, while the target is still frontmost.
            // Activating this popover first makes Claude collapse its web AX tree,
            // leaving only the generic "Claude" window title.
            state.captureActiveSignal()

            state.popoverWillOpen()
            state.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Activate so the popover is key and its controls render active
            // (not greyed out) the moment it opens. Detection already snapshotted
            // the source app above, and appActivated ignores us, so stealing focus
            // here doesn't corrupt the target.
            NSApp.activate(ignoringOtherApps: true)
            pinPopoverBelowMenuBar()

            // The content changes height when the phase changes (idle → copied),
            // which makes NSPopover re-lay-out to its (macOS 26-broken) position.
            // Re-pin on every resize so it stays under the icon.
            if let popWindow = popover.contentViewController?.view.window {
                stopObservingPopoverResize()
                observedPopoverWindow = popWindow
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(popoverWindowResized(_:)),
                    name: NSWindow.didResizeNotification,
                    object: popWindow
                )
            }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        state.cancelPendingDetection()
    }

    /// A transient popover also closes when the user clicks outside it. That path
    /// does not go through `togglePopover`, so delegate cleanup is required to
    /// avoid accumulating one resize observer on every open.
    func popoverDidClose(_ notification: Notification) {
        stopObservingPopoverResize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopObservingPopoverResize()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func stopObservingPopoverResize() {
        if let window = observedPopoverWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResizeNotification,
                object: window
            )
        }
        observedPopoverWindow = nil
    }

    @objc private func popoverWindowResized(_ note: Notification) {
        pinPopoverBelowMenuBar()
    }

    /// Force the popover window to sit directly under the menu bar icon. Runs on
    /// the next tick so it overrides NSPopover's own (incorrect) placement.
    private func pinPopoverBelowMenuBar() {
        DispatchQueue.main.async {
            guard let button = self.statusItem?.button,
                  let popWindow = self.popover.contentViewController?.view.window,
                  let buttonWindow = button.window else { return }
            // Keep the vibrant background from dimming to its inactive (lighter)
            // look — pin every visual-effect view to the active state.
            Self.forceActiveMaterial(in: popWindow.contentView)

            let buttonInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let gap: CGFloat = 4

            // Only correct the vertical position (macOS 26 places it too high).
            // Leave X to NSPopover so its arrow stays aligned under the icon.
            var origin = popWindow.frame.origin
            origin.y = buttonInScreen.minY - gap - popWindow.frame.height
            if abs(origin.y - popWindow.frame.origin.y) > 0.5 {
                popWindow.setFrameOrigin(origin)
            }
        }
    }

    /// Recursively force every NSVisualEffectView to `.active`, so the popover's
    /// background doesn't flip between light/dark as key status changes.
    private static func forceActiveMaterial(in view: NSView?) {
        guard let view else { return }
        if let effect = view as? NSVisualEffectView {
            effect.state = .active
        }
        for subview in view.subviews {
            forceActiveMaterial(in: subview)
        }
    }
}
