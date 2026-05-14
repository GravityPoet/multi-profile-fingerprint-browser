import AppKit
import Foundation

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
        window.title = Localization.t(
            "Multi-Profile Anti-Detect Browser (WIP)",
            "多账号反检测浏览器（开发中）"
        )
        window.center()

        let label = NSTextField(labelWithString: Localization.t(
            "v1.2.0 Camoufox anti-detect rewrite. Implementation in progress.",
            "v1.2.0 Camoufox 反检测重写，正在开发。"
        ))
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
