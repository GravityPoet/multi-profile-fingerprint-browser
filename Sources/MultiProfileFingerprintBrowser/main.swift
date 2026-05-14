import AppKit
import Foundation

// Multi-Profile Anti-Detect Browser
// v1.2.0 Camoufox rewrite — skeleton placeholder.
// Real shell implemented in Phase 1 after Camoufox spike completes.

@main
final class AntiDetectApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = preferredLanguageIsChinese
            ? "多账号反检测浏览器（开发中）"
            : "Multi-Profile Anti-Detect Browser (WIP)"
        window.center()

        let label = NSTextField(labelWithString: preferredLanguageIsChinese
            ? "v1.2.0 Camoufox 反检测重写。Phase 0 验证中。"
            : "v1.2.0 Camoufox anti-detect rewrite. Phase 0 spike in progress.")
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: frame)
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }
}

private var preferredLanguageIsChinese: Bool {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
}
