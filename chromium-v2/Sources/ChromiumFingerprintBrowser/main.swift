import AppKit
import CFNetwork
import Foundation
import UniformTypeIdentifiers

private let appID = "local.multi-profile-fingerprint-browser.chromium-v2"
private let appName = "Chromium Fingerprint Browser v2"
private let appIconResourceName = "AppIcon"
private let appIconResourceExtension = "icns"
private let controlWindowFrameDefaultsKey = "ChromiumFingerprintBrowser.ControlWindowFrame"

private var isChinese: Bool {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
}

private func t(_ en: String, _ zh: String) -> String {
    isChinese ? zh : en
}

private enum ProxyMode: String, Codable, CaseIterable {
    case direct
    case system
    case http
    case socks5

    var displayName: String {
        switch self {
        case .direct:
            return t("Direct", "直连")
        case .system:
            return t("Follow System", "跟随系统")
        case .http:
            return "HTTP"
        case .socks5:
            return "SOCKS5"
        }
    }

    var needsEndpoint: Bool {
        self == .http || self == .socks5
    }
}

private struct ProxyConfig: Codable, Equatable {
    var mode: ProxyMode
    var host: String
    var port: Int?

    static let systemDefault = ProxyConfig(mode: .system, host: "", port: nil)

    var normalized: ProxyConfig {
        guard mode.needsEndpoint else {
            return ProxyConfig(mode: mode, host: "", port: nil)
        }
        return ProxyConfig(mode: mode, host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    }

    var summary: String {
        let value = normalized
        switch value.mode {
        case .direct, .system:
            return value.mode.displayName
        case .http, .socks5:
            return "\(value.mode.displayName) \(value.host):\(value.port ?? 0)"
        }
    }

    var chromiumArgument: String? {
        let value = normalized
        guard value.mode.needsEndpoint, let port = value.port, !value.host.isEmpty else {
            return value.mode == .direct ? "--no-proxy-server" : nil
        }
        let scheme = value.mode == .http ? "http" : "socks5"
        return "--proxy-server=\(scheme)://\(value.host):\(port)"
    }

    var mappingKey: String? {
        let value = normalized
        guard value.mode.needsEndpoint, let port = value.port, !value.host.isEmpty else {
            return nil
        }
        return "\(value.mode.rawValue)://\(value.host.lowercased()):\(port)"
    }
}

private struct FingerprintProfile: Codable, Equatable {
    var presetID: String
    var displayName: String
    var userAgent: String
    var acceptLanguages: [String]
    var timezone: String
    var screenWidth: Int
    var screenHeight: Int
    var deviceScaleFactor: Double
    var webRTCPolicy: String
}

private enum Fingerprints {
    private static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let iPadUA = "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) CriOS/124.0.0.0 Mobile/15E148 Safari/604.1"
    private static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) CriOS/124.0.0.0 Mobile/15E148 Safari/604.1"

    static let presets: [FingerprintProfile] = [
        FingerprintProfile(
            presetID: "chrome-mac-us-west",
            displayName: "Chrome Mac US West",
            userAgent: chromeUA,
            acceptLanguages: ["en-US", "en"],
            timezone: "America/Los_Angeles",
            screenWidth: 1512,
            screenHeight: 982,
            deviceScaleFactor: 2.0,
            webRTCPolicy: "disable_non_proxied_udp"
        ),
        FingerprintProfile(
            presetID: "chrome-mac-us-east",
            displayName: "Chrome Mac US East",
            userAgent: chromeUA,
            acceptLanguages: ["en-US", "en"],
            timezone: "America/New_York",
            screenWidth: 1470,
            screenHeight: 956,
            deviceScaleFactor: 2.0,
            webRTCPolicy: "disable_non_proxied_udp"
        ),
        FingerprintProfile(
            presetID: "chrome-mac-cn",
            displayName: "Chrome Mac zh-CN",
            userAgent: chromeUA,
            acceptLanguages: ["zh-CN", "en-US"],
            timezone: "Asia/Shanghai",
            screenWidth: 1512,
            screenHeight: 982,
            deviceScaleFactor: 2.0,
            webRTCPolicy: "disable_non_proxied_udp"
        ),
        FingerprintProfile(
            presetID: "chrome-ipad-exp",
            displayName: "Chrome iPad experimental",
            userAgent: iPadUA,
            acceptLanguages: ["en-US", "en"],
            timezone: "America/Los_Angeles",
            screenWidth: 1024,
            screenHeight: 1366,
            deviceScaleFactor: 2.0,
            webRTCPolicy: "disable_non_proxied_udp"
        ),
        FingerprintProfile(
            presetID: "chrome-iphone-exp",
            displayName: "Chrome iPhone experimental",
            userAgent: iPhoneUA,
            acceptLanguages: ["en-US", "en"],
            timezone: "America/Los_Angeles",
            screenWidth: 393,
            screenHeight: 852,
            deviceScaleFactor: 3.0,
            webRTCPolicy: "disable_non_proxied_udp"
        ),
    ]

    static var defaultPreset: FingerprintProfile {
        presets[0]
    }

    static func preset(id: String) -> FingerprintProfile? {
        presets.first { $0.presetID == id }
    }
}

private struct BrowserProfile: Codable, Identifiable {
    var id: String
    var name: String
    var homepage: String
    var fingerprint: FingerprintProfile
    var proxy: ProxyConfig
    var createdAt: Date
    var lastEgressIP: String?
}

private struct EgressIPInfo: Codable {
    let ip: String
    let country: String?
    let org: String?
    let city: String?
    let region: String?
}

private enum ProfileStore {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appID, isDirectory: true)
    }

    static var profilesFile: URL {
        supportDirectory.appendingPathComponent("profiles.json")
    }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    static func load() -> [BrowserProfile] {
        do {
            try ensureSupportDirectory()
            if FileManager.default.fileExists(atPath: profilesFile.path) {
                let data = try Data(contentsOf: profilesFile)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let profiles = try decoder.decode([BrowserProfile].self, from: data)
                if !profiles.isEmpty {
                    return profiles
                }
            }
        } catch {
            NSLog("Failed to load Chromium v2 profiles: \(error.localizedDescription)")
        }
        let profile = BrowserProfile(
            id: UUID().uuidString,
            name: t("Default Chromium", "默认 Chromium"),
            homepage: "https://browserleaks.com/javascript",
            fingerprint: Fingerprints.defaultPreset,
            proxy: .systemDefault,
            createdAt: Date(),
            lastEgressIP: nil
        )
        save([profile])
        return [profile]
    }

    static func save(_ profiles: [BrowserProfile]) {
        do {
            try ensureSupportDirectory()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try data.write(to: profilesFile, options: .atomic)
        } catch {
            NSLog("Failed to save Chromium v2 profiles: \(error.localizedDescription)")
        }
    }

    static func userDataDirectory(for profile: BrowserProfile) throws -> URL {
        let dir = try profileRootDirectory(for: profile).appendingPathComponent("user-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func profileRootDirectory(for profile: BrowserProfile) throws -> URL {
        let root = supportDirectory.appendingPathComponent("profiles", isDirectory: true)
        let dir = root.appendingPathComponent(profile.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func testPageURL(for profile: BrowserProfile) throws -> URL {
        let dir = try profileRootDirectory(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fingerprint-test.html")
        try FingerprintTestPage.html(profile: profile).data(using: .utf8)?.write(to: file, options: .atomic)
        return file
    }
}

private enum EmbeddedCEFBrowser {
    static func executableURL() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["MPFB_CEF_EXECUTABLE"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.isExecutableFile(atPath: raw) {
            return URL(fileURLWithPath: raw)
        }

        var candidates: [URL] = []
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            candidates.append(
                frameworksURL
                    .appendingPathComponent("ChromiumFingerprintCEF.app", isDirectory: true)
                    .appendingPathComponent("Contents/MacOS/ChromiumFingerprintCEF")
            )
        }

        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("cef/build/Release/ChromiumFingerprintCEF.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS/ChromiumFingerprintCEF")
        )

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private enum ChromiumLauncher {
    static func launch(profile: BrowserProfile, targetURL: URL? = nil) throws {
        guard let executable = EmbeddedCEFBrowser.executableURL() else {
            throw NSError(
                domain: "ChromiumFingerprintBrowser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: t(
                    "Bundled CEF browser is missing. Run ./packaging/make-app.sh, or set MPFB_CEF_EXECUTABLE to ChromiumFingerprintCEF.",
                    "内置 CEF 浏览器组件缺失。请运行 ./packaging/make-app.sh，或设置 MPFB_CEF_EXECUTABLE 指向 ChromiumFingerprintCEF。"
                )]
            )
        }

        let profileRoot = try ProfileStore.profileRootDirectory(for: profile)
        let userDataDir = try ProfileStore.userDataDirectory(for: profile)
        let target = targetURL?.absoluteString ?? profile.homepage
        var args = [
            "--mpfb-profile-id=\(profile.id)",
            "--mpfb-profile-name=\(profile.name)",
            "--mpfb-homepage=\(target)",
            "--mpfb-user-agent=\(profile.fingerprint.userAgent)",
            "--mpfb-accept-languages=\(profile.fingerprint.acceptLanguages.joined(separator: ","))",
            "--mpfb-timezone=\(profile.fingerprint.timezone)",
            "--mpfb-web-rtc-policy=\(profile.fingerprint.webRTCPolicy)",
            "--mpfb-device-scale-factor=\(profile.fingerprint.deviceScaleFactor)",
            "--mpfb-screen-width=\(profile.fingerprint.screenWidth)",
            "--mpfb-screen-height=\(profile.fingerprint.screenHeight)",
            "--mpfb-root-cache-path=\(profileRoot.path)",
            "--mpfb-cache-path=\(userDataDir.path)",
            "--mpfb-window-bounds-path=\(profileRoot.appendingPathComponent("cef-window-bounds.txt").path)",
            "--mpfb-proxy-mode=\(profile.proxy.normalized.mode.rawValue)",
        ]

        let proxy = profile.proxy.normalized
        if proxy.mode.needsEndpoint, let port = proxy.port, !proxy.host.isEmpty {
            args.append("--mpfb-proxy-host=\(proxy.host)")
            args.append("--mpfb-proxy-port=\(port)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = profile.fingerprint.timezone
        process.environment = environment
        try process.run()
    }
}

private enum ProxyCheckService {
    static func check(config: ProxyConfig, completion: @escaping (Result<EgressIPInfo, Error>) -> Void) {
        let endpoint = URL(string: "https://ipinfo.io/json")!
        let session = URLSession(configuration: sessionConfiguration(for: config))
        let task = session.dataTask(with: endpoint) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "ChromiumFingerprintBrowser.ProxyCheck",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: t("IP lookup failed", "出口 IP 查询失败")]
                    )))
                }
                return
            }
            do {
                let info = try JSONDecoder().decode(EgressIPInfo.self, from: data)
                DispatchQueue.main.async { completion(.success(info)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
    }

    private static func sessionConfiguration(for config: ProxyConfig) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18

        switch config.normalized.mode {
        case .system:
            break
        case .direct:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false,
            ]
        case .http:
            if let port = config.port, !config.host.isEmpty {
                configuration.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: true,
                    kCFNetworkProxiesHTTPProxy as String: config.host,
                    kCFNetworkProxiesHTTPPort as String: port,
                    kCFNetworkProxiesHTTPSEnable as String: true,
                    kCFNetworkProxiesHTTPSProxy as String: config.host,
                    kCFNetworkProxiesHTTPSPort as String: port,
                ]
            }
        case .socks5:
            if let port = config.port, !config.host.isEmpty {
                configuration.connectionProxyDictionary = [
                    kCFNetworkProxiesSOCKSEnable as String: true,
                    kCFNetworkProxiesSOCKSProxy as String: config.host,
                    kCFNetworkProxiesSOCKSPort as String: port,
                ]
            }
        }

        return configuration
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem?
    private var profiles: [BrowserProfile] = []
    private var selectedIndex = 0

    private let profilePopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let homepageField = NSTextField()
    private let fingerprintPopup = NSPopUpButton()
    private let proxyPopup = NSPopUpButton()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureApplicationIcon()
        profiles = ProfileStore.load()
        buildMenu()
        installStatusItem()
        buildWindow()
        reloadUI()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureApplicationIcon() {
        guard let image = Self.loadAppIcon() else {
            return
        }
        NSApp.applicationIconImage = image
    }

    private static func loadAppIcon(fitting size: NSSize? = nil) -> NSImage? {
        let sourceImage: NSImage?
        if let iconURL = Bundle.main.url(forResource: appIconResourceName, withExtension: appIconResourceExtension) {
            sourceImage = NSImage(contentsOf: iconURL)
        } else {
            sourceImage = NSApp.applicationIconImage
        }

        guard let image = sourceImage?.copy() as? NSImage else {
            return nil
        }
        if let size {
            image.size = size
        }
        return image
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = Self.loadAppIcon(fitting: NSSize(width: 22, height: 22))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.alignment = .center
            button.toolTip = appName
        }

        let menu = NSMenu(title: appName)
        menu.addItem(targetedItem(t("Show Window", "显示窗口"), #selector(showWindow(_:)), ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(targetedItem(t("Launch Current Profile", "启动当前空间"), #selector(launchProfile(_:)), ""))
        menu.addItem(targetedItem(t("Open Fingerprint Test", "打开指纹检测"), #selector(openFingerprintTest(_:)), ""))
        menu.addItem(targetedItem(t("Check Egress IP", "检测出口 IP"), #selector(checkIP(_:)), ""))
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: t("Quit \(appName)", "退出 \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu
    }

    @objc private func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistControlWindowFrame()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persistControlWindowFrame()
        sender.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        persistControlWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistControlWindowFrame()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("Quit \(appName)", "退出 \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: t("File", "文件"))
        fileMenu.addItem(targetedItem(t("Launch Profile", "启动空间"), #selector(launchProfile(_:)), "r"))
        fileMenu.addItem(targetedItem(t("Open Fingerprint Test", "打开指纹检测"), #selector(openFingerprintTest(_:)), "t"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(targetedItem(t("Export Profile...", "导出空间..."), #selector(exportProfile(_:)), ""))
        fileMenu.addItem(targetedItem(t("Import Profile...", "导入空间..."), #selector(importProfile(_:)), ""))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
    }

    private func targetedItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildWindow() {
        let defaultRect = NSRect(x: 0, y: 0, width: 760, height: 520)
        let restoredFrame = Self.restoredControlWindowFrame()
        window = NSWindow(
            contentRect: restoredFrame ?? defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 480)
        if restoredFrame == nil {
            window.center()
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        window.contentView = root

        let title = NSTextField(labelWithString: t("Chromium/CEF v2 Experiment", "Chromium/CEF v2 实验版"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: t(
            "Each profile opens the bundled CEF/Chromium runtime with its own cache, cookies, localStorage, proxy, timezone, language, UA, screen preset, and WebRTC policy.",
            "每个空间打开随 app 打包的 CEF/Chromium 内核，并使用独立 cache、cookies、localStorage、代理、时区、语言、UA、屏幕预设和 WebRTC 策略。"
        ))
        subtitle.maximumNumberOfLines = 3
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        root.addArrangedSubview(row(t("Profile", "空间"), profilePopup, width: 280, action: #selector(profileChanged(_:))))
        root.addArrangedSubview(row(t("Name", "名称"), nameField, width: 360))
        root.addArrangedSubview(row(t("Homepage", "首页"), homepageField, width: 520))
        root.addArrangedSubview(row(t("Fingerprint", "指纹"), fingerprintPopup, width: 300, action: #selector(fingerprintChanged(_:))))
        root.addArrangedSubview(proxyRow())
        root.addArrangedSubview(buttonRow())

        statusLabel.maximumNumberOfLines = 5
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)
    }

    private func persistControlWindowFrame() {
        guard window != nil else {
            return
        }
        let frame = window.frame
        UserDefaults.standard.set([
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height,
        ], forKey: controlWindowFrameDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private static func restoredControlWindowFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.dictionary(forKey: controlWindowFrameDefaultsKey),
              let x = raw["x"] as? CGFloat,
              let y = raw["y"] as? CGFloat,
              let width = raw["width"] as? CGFloat,
              let height = raw["height"] as? CGFloat else {
            return nil
        }
        let frame = NSRect(x: x, y: y, width: max(width, 700), height: max(height, 480))
        return clampToVisibleScreen(frame)
    }

    private static func clampToVisibleScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else {
            return frame
        }
        let visible = screen.visibleFrame
        var clamped = frame
        clamped.size.width = min(max(clamped.size.width, 700), visible.size.width)
        clamped.size.height = min(max(clamped.size.height, 480), visible.size.height)

        if clamped.maxX > visible.maxX {
            clamped.origin.x = visible.maxX - clamped.size.width
        }
        if clamped.minX < visible.minX {
            clamped.origin.x = visible.minX
        }
        if clamped.maxY > visible.maxY {
            clamped.origin.y = visible.maxY - clamped.size.height
        }
        if clamped.minY < visible.minY {
            clamped.origin.y = visible.minY
        }
        return clamped.integral
    }

    private func row(_ label: String, _ view: NSControl, width: CGFloat, action: Selector? = nil) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.frame.size.width = 92
        view.frame.size.width = width
        if let action {
            view.target = self
            view.action = action
        }
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(view)
        return stack
    }

    private func proxyRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        let label = NSTextField(labelWithString: t("Proxy", "代理"))
        label.alignment = .right
        label.frame.size.width = 92
        proxyPopup.frame.size.width = 130
        proxyPopup.target = self
        proxyPopup.action = #selector(proxyChanged(_:))
        hostField.placeholderString = "127.0.0.1"
        hostField.frame.size.width = 180
        portField.placeholderString = "18001"
        portField.frame.size.width = 80

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(proxyPopup)
        stack.addArrangedSubview(hostField)
        stack.addArrangedSubview(portField)
        return stack
    }

    private func buttonRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 102, height: 1))
        stack.addArrangedSubview(spacer)
        [
            button(t("Save", "保存"), #selector(saveCurrent(_:))),
            button(t("Launch", "启动"), #selector(launchProfile(_:))),
            button(t("Fingerprint Test", "指纹检测"), #selector(openFingerprintTest(_:))),
            button(t("Check IP", "检测 IP"), #selector(checkIP(_:))),
            button(t("Add", "新增"), #selector(addProfile(_:))),
            button(t("Delete", "删除"), #selector(deleteProfile(_:))),
        ].forEach { stack.addArrangedSubview($0) }
        return stack
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reloadUI() {
        profilePopup.removeAllItems()
        for profile in profiles {
            profilePopup.addItem(withTitle: profile.name)
        }
        selectedIndex = min(selectedIndex, max(0, profiles.count - 1))
        profilePopup.selectItem(at: selectedIndex)

        fingerprintPopup.removeAllItems()
        for preset in Fingerprints.presets {
            fingerprintPopup.addItem(withTitle: preset.displayName)
            fingerprintPopup.lastItem?.representedObject = preset.presetID
        }

        proxyPopup.removeAllItems()
        for mode in ProxyMode.allCases {
            proxyPopup.addItem(withTitle: mode.displayName)
            proxyPopup.lastItem?.representedObject = mode.rawValue
        }

        loadSelectedProfileIntoFields()
    }

    private func loadSelectedProfileIntoFields() {
        guard profiles.indices.contains(selectedIndex) else { return }
        let profile = profiles[selectedIndex]
        nameField.stringValue = profile.name
        homepageField.stringValue = profile.homepage
        if let index = Fingerprints.presets.firstIndex(where: { $0.presetID == profile.fingerprint.presetID }) {
            fingerprintPopup.selectItem(at: index)
        }
        if let index = ProxyMode.allCases.firstIndex(of: profile.proxy.mode) {
            proxyPopup.selectItem(at: index)
        }
        hostField.stringValue = profile.proxy.host
        portField.stringValue = profile.proxy.port.map(String.init) ?? ""
        setStatus(summary(for: profile))
    }

    private func summary(for profile: BrowserProfile) -> String {
        let ip = profile.lastEgressIP ?? t("not checked", "未检测")
        let executable = EmbeddedCEFBrowser.executableURL()?.path ?? t("not found", "未找到")
        return t(
            "Embedded CEF: \(executable)\nUser data: \(ProfileStore.supportDirectory.path)/profiles/\(profile.id)/user-data\nProxy: \(profile.proxy.summary)\nLast egress IP: \(ip)",
            "内置 CEF：\(executable)\n用户数据：\(ProfileStore.supportDirectory.path)/profiles/\(profile.id)/user-data\n代理：\(profile.proxy.summary)\n上次出口 IP：\(ip)"
        )
    }

    private func currentProfileFromFields() -> BrowserProfile? {
        guard profiles.indices.contains(selectedIndex) else { return nil }
        var profile = profiles[selectedIndex]
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let homepage = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = name.isEmpty ? profile.name : name
        profile.homepage = homepage.isEmpty ? "about:blank" : homepage
        if let presetID = fingerprintPopup.selectedItem?.representedObject as? String,
           let preset = Fingerprints.preset(id: presetID) {
            profile.fingerprint = preset
        }
        if let proxy = readProxyConfig() {
            profile.proxy = proxy
        } else {
            return nil
        }
        return profile
    }

    private func readProxyConfig() -> ProxyConfig? {
        let raw = proxyPopup.selectedItem?.representedObject as? String
        let mode = raw.flatMap(ProxyMode.init(rawValue:)) ?? .system
        guard mode.needsEndpoint else {
            return ProxyConfig(mode: mode, host: "", port: nil)
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            setStatus(t("Proxy host is required.", "必须填写代理主机。"))
            return nil
        }
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            setStatus(t("Proxy port must be 1-65535.", "代理端口必须在 1-65535 之间。"))
            return nil
        }
        return ProxyConfig(mode: mode, host: host, port: port)
    }

    private func persistFields() -> BrowserProfile? {
        guard let profile = currentProfileFromFields() else { return nil }
        profiles[selectedIndex] = profile
        ProfileStore.save(profiles)
        reloadUI()
        return profile
    }

    private func setStatus(_ value: String) {
        statusLabel.stringValue = value
    }

    @objc private func profileChanged(_ sender: Any?) {
        selectedIndex = max(0, profilePopup.indexOfSelectedItem)
        loadSelectedProfileIntoFields()
    }

    @objc private func fingerprintChanged(_ sender: Any?) {
        guard let presetID = fingerprintPopup.selectedItem?.representedObject as? String,
              let preset = Fingerprints.preset(id: presetID) else { return }
        setStatus(t(
            "Preset: \(preset.displayName), \(preset.timezone), \(preset.screenWidth)x\(preset.screenHeight), DPR \(preset.deviceScaleFactor)",
            "预设：\(preset.displayName)，\(preset.timezone)，\(preset.screenWidth)x\(preset.screenHeight)，DPR \(preset.deviceScaleFactor)"
        ))
    }

    @objc private func proxyChanged(_ sender: Any?) {
        let raw = proxyPopup.selectedItem?.representedObject as? String
        let mode = raw.flatMap(ProxyMode.init(rawValue:)) ?? .system
        hostField.isEnabled = mode.needsEndpoint
        portField.isEnabled = mode.needsEndpoint
    }

    @objc private func saveCurrent(_ sender: Any?) {
        guard let profile = persistFields() else { return }
        setStatus(t("Saved \(profile.name).", "已保存 \(profile.name)。"))
    }

    @objc private func launchProfile(_ sender: Any?) {
        guard let profile = persistFields() else { return }
        do {
            try ChromiumLauncher.launch(profile: profile)
            setStatus(t("Launched \(profile.name) with \(profile.proxy.summary).", "已用 \(profile.proxy.summary) 启动 \(profile.name)。"))
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    @objc private func openFingerprintTest(_ sender: Any?) {
        guard let profile = persistFields() else { return }
        do {
            let url = try ProfileStore.testPageURL(for: profile)
            try ChromiumLauncher.launch(profile: profile, targetURL: url)
            setStatus(t("Opened local fingerprint test for \(profile.name).", "已打开 \(profile.name) 的本地指纹检测页。"))
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    @objc private func checkIP(_ sender: Any?) {
        guard let profile = persistFields() else { return }
        setStatus(t("Checking egress IP for \(profile.proxy.summary)...", "正在检测 \(profile.proxy.summary) 的出口 IP..."))
        ProxyCheckService.check(config: profile.proxy) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                self.profiles[self.selectedIndex].lastEgressIP = info.ip
                ProfileStore.save(self.profiles)
                let sameProxy = self.profiles.filter { $0.id != profile.id && $0.proxy.mappingKey == profile.proxy.mappingKey && profile.proxy.mappingKey != nil }.map(\.name)
                let sameIP = self.profiles.filter { $0.id != profile.id && $0.lastEgressIP == info.ip }.map(\.name)
                let location = [info.country, info.region, info.city].compactMap { $0 }.joined(separator: " / ")
                self.setStatus(t(
                    "IP: \(info.ip)\nLocation: \(location.isEmpty ? "unknown" : location)\nASN/org: \(info.org ?? "unknown")\nSame proxy profiles: \(sameProxy.isEmpty ? "none" : sameProxy.joined(separator: ", "))\nSame IP profiles: \(sameIP.isEmpty ? "none" : sameIP.joined(separator: ", "))",
                    "IP：\(info.ip)\n国家/地区：\(location.isEmpty ? "未知" : location)\nASN/组织：\(info.org ?? "未知")\n同代理空间：\(sameProxy.isEmpty ? "无" : sameProxy.joined(separator: "、"))\n同 IP 空间：\(sameIP.isEmpty ? "无" : sameIP.joined(separator: "、"))"
                ))
            case .failure(let error):
                self.setStatus(error.localizedDescription)
            }
        }
    }

    @objc private func addProfile(_ sender: Any?) {
        let profile = BrowserProfile(
            id: UUID().uuidString,
            name: t("New Chromium Profile", "新 Chromium 空间"),
            homepage: "https://browserleaks.com/javascript",
            fingerprint: Fingerprints.defaultPreset,
            proxy: .systemDefault,
            createdAt: Date(),
            lastEgressIP: nil
        )
        profiles.append(profile)
        selectedIndex = profiles.count - 1
        ProfileStore.save(profiles)
        reloadUI()
    }

    @objc private func deleteProfile(_ sender: Any?) {
        guard profiles.count > 1, profiles.indices.contains(selectedIndex) else {
            setStatus(t("Keep at least one profile.", "至少保留一个空间。"))
            return
        }
        profiles.remove(at: selectedIndex)
        selectedIndex = max(0, selectedIndex - 1)
        ProfileStore.save(profiles)
        reloadUI()
    }

    @objc private func exportProfile(_ sender: Any?) {
        guard let profile = persistFields() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name)-chromium-profile.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(profile).write(to: url, options: .atomic)
                self?.setStatus(t("Exported profile config.", "已导出空间配置。"))
            } catch {
                self?.setStatus(error.localizedDescription)
            }
        }
    }

    @objc private func importProfile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var profile = try decoder.decode(BrowserProfile.self, from: data)
                profile.id = UUID().uuidString
                profile.name = uniqueName(profile.name)
                profile.lastEgressIP = nil
                profiles.append(profile)
                selectedIndex = profiles.count - 1
                ProfileStore.save(profiles)
                reloadUI()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    private func uniqueName(_ base: String) -> String {
        if !profiles.contains(where: { $0.name == base }) {
            return base
        }
        var index = 2
        while profiles.contains(where: { $0.name == "\(base) \(index)" }) {
            index += 1
        }
        return "\(base) \(index)"
    }
}

private enum FingerprintTestPage {
    static func html(profile: BrowserProfile) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Chromium v2 Fingerprint Test</title>
          <style>
            :root { color-scheme: light dark; }
            body { margin: 0; padding: 24px; font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f8fafc; color: #111827; }
            main { max-width: 1040px; margin: 0 auto; }
            h1 { margin: 0 0 8px; font-size: 22px; }
            p { margin: 0 0 16px; color: #4b5563; line-height: 1.5; }
            table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid #d1d5db; }
            th, td { border-bottom: 1px solid #e5e7eb; padding: 8px 10px; text-align: left; vertical-align: top; }
            th { width: 260px; }
            code { word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            @media (prefers-color-scheme: dark) {
              body { background: #0f172a; color: #e5e7eb; }
              p { color: #94a3b8; }
              table { background: #111827; border-color: #334155; }
              th, td { border-bottom-color: #1f2937; }
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Chromium v2 Fingerprint Test</h1>
            <p>Profile: \(escape(profile.name)). Expected preset: \(escape(profile.fingerprint.displayName)). Proxy mapping: \(escape(profile.proxy.summary)).</p>
            <table><tbody id="report"></tbody></table>
          </main>
          <script>
            const rows = [];
            const text = value => {
              if (value === undefined) return 'undefined';
              if (value === null) return 'null';
              if (typeof value === 'object') {
                try { return JSON.stringify(value); } catch (_) { return String(value); }
              }
              return String(value);
            };
            const hash = value => {
              let h = 2166136261;
              const raw = String(value);
              for (let i = 0; i < raw.length; i += 1) {
                h ^= raw.charCodeAt(i);
                h = Math.imul(h, 16777619);
              }
              return (h >>> 0).toString(16).padStart(8, '0');
            };
            const canvasHash = () => {
              const c = document.createElement('canvas');
              c.width = 220; c.height = 64;
              const x = c.getContext('2d');
              x.fillStyle = '#f5f5f5'; x.fillRect(0, 0, c.width, c.height);
              x.fillStyle = '#123456'; x.font = '18px -apple-system, Arial';
              x.fillText('Chromium v2 123', 12, 34);
              return hash(c.toDataURL());
            };
            const webgl = () => {
              const c = document.createElement('canvas');
              const gl = c.getContext('webgl') || c.getContext('experimental-webgl');
              if (!gl) return { available: false };
              const dbg = gl.getExtension('WEBGL_debug_renderer_info');
              return {
                available: true,
                vendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
                renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
                version: gl.getParameter(gl.VERSION)
              };
            };
            const add = (key, value) => rows.push([key, text(value)]);
            add('User-Agent', navigator.userAgent);
            add('navigator.language', navigator.language);
            add('navigator.languages', Array.from(navigator.languages || []));
            add('timezone', Intl.DateTimeFormat().resolvedOptions().timeZone);
            add('screen', { width: screen.width, height: screen.height, availWidth: screen.availWidth, availHeight: screen.availHeight, colorDepth: screen.colorDepth });
            add('window', { innerWidth, innerHeight, outerWidth, outerHeight, devicePixelRatio });
            add('hardwareConcurrency', navigator.hardwareConcurrency);
            add('maxTouchPoints', navigator.maxTouchPoints);
            add('WebRTC constructors', { RTCPeerConnection: typeof RTCPeerConnection, RTCIceCandidate: typeof RTCIceCandidate });
            add('Canvas hash', canvasHash());
            add('WebGL', webgl());
            document.getElementById('report').innerHTML = rows.map(([key, value]) => '<tr><th>' + key + '</th><td><code>' + value.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])) + '</code></td></tr>').join('');
          </script>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

@main
private enum Main {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
