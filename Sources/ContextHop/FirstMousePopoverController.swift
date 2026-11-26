import AppKit
import SwiftUI

/// NSHostingView that accepts the first mouse click, so buttons in the popover
/// fire on a single click even while ContextHop is in the background (the user
/// has switched to the target chat). Without this, a background app's window
/// swallows the first click just to activate itself.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosting controller that installs `FirstMouseHostingView` while keeping the
/// automatic SwiftUI sizing NSHostingController provides.
final class FirstMousePopoverController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}
