import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: RootView())

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Localization.t(
            "Multi-Profile Anti-Detect Browser",
            "多账号反检测浏览器"
        )
        window.contentViewController = hosting
        window.center()
        window.setFrameAutosaveName("main")
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill script subprocesses first, then browser processes.
        ScriptRunner.shared.terminateAll()
        for launched in CamoufoxLauncher.shared.running {
            CamoufoxLauncher.shared.terminate(profileID: launched.profileID)
        }
    }
}
