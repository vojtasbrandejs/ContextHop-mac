import AppKit

// Hidden debug mode: `--axdump <bundle-id>` dumps the target app's AX tree and
// exits before NSApplication ever starts (see AXDump.swift for why it exists).
if let dumpIndex = CommandLine.arguments.firstIndex(of: "--axdump"),
   CommandLine.arguments.indices.contains(dumpIndex + 1) {
    AXDump.run(bundleID: CommandLine.arguments[dumpIndex + 1])
}

// Menu bar app without an Xcode project: plain NSApplication with .accessory
// activation policy (no Dock icon, no main menu). The status item and popover
// live in AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
