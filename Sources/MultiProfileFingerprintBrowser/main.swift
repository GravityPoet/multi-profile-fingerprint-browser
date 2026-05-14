import AppKit
import Foundation

if ProcessInfo.processInfo.environment["MPFB_SMOKE"] == "1" {
    SmokeTest.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
