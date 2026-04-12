import AppKit

/// An `NSApplicationDelegate` used when the package is launched via `swift run` without a
/// proper `.app` bundle. It promotes the process to a regular foreground app, activates it,
/// and enables standard macOS app behaviors that SwiftUI otherwise infers from Info.plist.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` executable starts with no activation policy set, so the process
        // runs as a background/accessory app — no dock icon, no focus, no key events, and
        // NSOpenPanel immediately loses focus. Force regular foreground behavior.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Standard single-window macOS app: quit when the last window closes.
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // Silences the AppKit warning on macOS 14+ and opts into secure restoration.
        true
    }
}
