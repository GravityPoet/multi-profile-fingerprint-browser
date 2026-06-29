import AppKit
import Foundation

enum CamoufoxLauncherError: Error, LocalizedError {
    case runtimeNotReady
    case alreadyRunning(UUID)
    case consistencyFailed(String)
    case spawnFailed(underlying: Error)
    case ioFailure(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady:
            return "Camoufox runtime is not ready yet. Download the runtime first."
        case .alreadyRunning(let id):
            return "Profile \(id.uuidString) is already running"
        case .consistencyFailed(let message):
            return "Fingerprint consistency check failed:\n\(message)"
        case .spawnFailed(let err):
            return "Failed to launch Camoufox: \(err.localizedDescription)"
        case .ioFailure(let url, let err):
            return "I/O failure at \(url.path): \(err.localizedDescription)"
        }
    }
}

/// Represents an in-flight Camoufox process tied to a Profile.
final class LaunchedProfile {
    let profileID: UUID
    let process: Process
    let marionettePort: Int?
    let proxyRelay: ProxyRelay?
    let startedAt: Date

    init(profileID: UUID, process: Process, marionettePort: Int?, proxyRelay: ProxyRelay?, startedAt: Date) {
        self.profileID = profileID
        self.process = process
        self.marionettePort = marionettePort
        self.proxyRelay = proxyRelay
        self.startedAt = startedAt
    }

    var isRunning: Bool { process.isRunning }
}

/// Spawns and supervises Camoufox instances, one per Profile.
/// Configuration is injected via:
///   - `CAMOU_CONFIG_N` env-var chunks (per upstream Python wrapper)
///   - `<firefox-profile>/user.js` (proxy, accept_languages, Marionette port)
final class CamoufoxLauncher {
    static let shared = CamoufoxLauncher()

    private static let camoufoxBundleIdentifier = "org.mozilla.camoufox"
    private static let activationDelays: [TimeInterval] = [0.0, 0.4, 0.9, 1.6, 2.6, 3.8]

    /// Chunk size matches the upstream Python wrapper for non-Windows hosts.
    /// `pythonlib/camoufox/utils.py:80` — `32767 if OS != 'win' else 2047`.
    private let configChunkSize = 32767

    private let registryQueue = DispatchQueue(
        label: "local.multi-profile-fingerprint-browser.launcher-registry"
    )
    private var registry: [UUID: LaunchedProfile] = [:]
    private var listeners: [() -> Void] = []

    private init() {}

    // MARK: Registry

    var running: [LaunchedProfile] {
        registryQueue.sync { Array(registry.values) }
    }

    func runningProfile(id: UUID) -> LaunchedProfile? {
        registryQueue.sync { registry[id] }
    }

    func observe(_ listener: @escaping () -> Void) {
        registryQueue.sync { listeners.append(listener) }
    }

    private func notifyChange() {
        let snapshot = registryQueue.sync { listeners }
        DispatchQueue.main.async { snapshot.forEach { $0() } }
    }

    // MARK: Launch / Terminate

    /// Launches Camoufox for the given profile. Throws if the runtime is not
    /// downloaded, if the profile is already running, or if the process
    /// fails to spawn.
    /// - Parameter geo: Optional geolocation info resolved from proxy exit IP.
    ///   When provided, injects concrete timezone so it matches the exit region.
    @discardableResult
    func launch(_ profile: Profile, geo: ProxyGeoResolver.GeoInfo? = nil, skipConsistencyGate: Bool = false) throws -> LaunchedProfile {
        if let existing = runningProfile(id: profile.id), existing.isRunning {
            throw CamoufoxLauncherError.alreadyRunning(profile.id)
        }

        var launchFingerprint = profile.fingerprint
        applyLaunchOverrides(to: &launchFingerprint)
        var launchProfile = profile
        launchProfile.fingerprint = launchFingerprint

        if !skipConsistencyGate {
            let report = FingerprintConsistencyScorer.score(profile: launchProfile, geo: geo)
            if !report.canLaunch {
                throw CamoufoxLauncherError.consistencyFailed(report.summary)
            }
        }

        let binaryURL = try CamoufoxRuntime.shared.ensureReady()

        let firefoxProfileDir = AppPaths.firefoxProfileDir(for: profile)
        do {
            try FileManager.default.createDirectory(
                at: firefoxProfileDir,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.profileDir(for: profile).path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: firefoxProfileDir.path)
        } catch {
            throw CamoufoxLauncherError.ioFailure(firefoxProfileDir, underlying: error)
        }

        let proxyRelay = try profile.proxy.isEnabled ? ProxyRelay.start(for: profile.proxy) : nil

        var marionettePort: Int? = nil
        if profile.marionetteEnabled {
            marionettePort = try PortAllocator.shared.allocate()
        }

        try writeUserJS(
            for: launchProfile,
            marionettePort: marionettePort,
            proxyRelay: proxyRelay
        )
        try installProfileLanguagePackIfNeeded(firefoxProfileDir: firefoxProfileDir)
        try writeUserChromeCSS(firefoxProfileDir: firefoxProfileDir)

        // Inject timezone that matches the proxy exit IP.
        // The Camoufox binary accepts concrete timezone via the "timezone" key
        // (verified: old presets used it). The "geoip" key is a Python wrapper
        // feature — the binary ignores it, so we resolve the timezone ourselves.
        if profile.proxy.isEnabled {
            // Remove the no-op geoip key if set by old code.
            launchFingerprint.geoip = nil
            if let geo {
                // Concrete timezone from proxy exit IP — the gold standard.
                launchFingerprint.timezone = geo.timezone
                AppLogger.info("Injected timezone from proxy geo: \(geo.timezone)")
            } else if launchFingerprint.timezone == nil || launchFingerprint.timezone?.isEmpty == true {
                // No geo resolved and no timezone set — use UTC as safe fallback.
                // Better to be "UTC user" than "timezone leaks real location".
                launchFingerprint.timezone = "UTC"
                AppLogger.warn("No proxy geo; falling back to UTC timezone")
            }
            // If fingerprint already has a timezone (from preset), keep it —
            // user chose that preset knowing their proxy region.
        }

        let env = try buildEnvironment(fingerprint: launchFingerprint)
        let process = Process()
        process.executableURL = binaryURL
        process.environment = env
        process.arguments = buildArguments(
            firefoxProfileDir: firefoxProfileDir,
            marionettePort: marionettePort
        )

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            AppLogger.info("Camoufox exited for profile \(profile.id) status=\(proc.terminationStatus)")
            self.registryQueue.sync {
                self.registry.removeValue(forKey: profile.id)
                if let port = marionettePort {
                    PortAllocator.shared.release(port)
                }
                proxyRelay?.stop()
            }
            self.notifyChange()
        }

        do {
            try process.run()
            activateBrowser(
                processIdentifier: process.processIdentifier,
                binaryURL: binaryURL
            )
        } catch {
            if let port = marionettePort {
                PortAllocator.shared.release(port)
            }
            proxyRelay?.stop()
            throw CamoufoxLauncherError.spawnFailed(underlying: error)
        }

        let launched = LaunchedProfile(
            profileID: profile.id,
            process: process,
            marionettePort: marionettePort,
            proxyRelay: proxyRelay,
            startedAt: Date()
        )
        registryQueue.sync { registry[profile.id] = launched }
        notifyChange()

        AppLogger.info(
            "Launched Camoufox for profile \(profile.id) pid=\(process.processIdentifier) port=\(marionettePort.map(String.init) ?? "n/a")"
        )

        try? ProfileStore.shared.recordLaunch(of: profile)
        return launched
    }

    private func activateBrowser(processIdentifier: Int32, binaryURL: URL) {
        let pid = pid_t(processIdentifier)
        let appBundleURL = appBundleURL(for: binaryURL)
        for (idx, delay) in Self.activationDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                let activated = self.activateRunningBrowser(
                    processIdentifier: pid,
                    appBundleURL: appBundleURL
                )
                if !activated, idx >= 3 {
                    self.activateBrowserWithAppleScript(processIdentifier: pid)
                }
            }
        }
    }

    @discardableResult
    private func activateRunningBrowser(processIdentifier pid: pid_t, appBundleURL: URL?) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.camoufoxBundleIdentifier {
            return true
        }

        var candidates: [NSRunningApplication] = []
        if let byPID = NSRunningApplication(processIdentifier: pid) {
            candidates.append(byPID)
        }
        candidates.append(
            contentsOf: NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.camoufoxBundleIdentifier
            )
        )

        var seenPIDs: Set<pid_t> = []
        let apps = candidates.filter { app in
            guard !app.isTerminated, seenPIDs.insert(app.processIdentifier).inserted else {
                return false
            }
            if app.processIdentifier == pid {
                return true
            }
            guard let appBundleURL else {
                return true
            }
            return sameFileURL(app.bundleURL, appBundleURL)
        }

        var didActivate = false
        for app in apps {
            app.unhide()
            if app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                didActivate = true
            }
        }
        return didActivate ||
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.camoufoxBundleIdentifier
    }

    private func activateBrowserWithAppleScript(processIdentifier pid: pid_t) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.camoufoxBundleIdentifier {
            return
        }

        let script = """
        tell application "System Events"
            set pidMatches to application processes whose unix id is \(pid)
            if (count of pidMatches) > 0 then
                set frontmost of item 1 of pidMatches to true
            else
                set bundleMatches to application processes whose bundle identifier is "\(Self.camoufoxBundleIdentifier)"
                if (count of bundleMatches) > 0 then set frontmost of item 1 of bundleMatches to true
            end if
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func appBundleURL(for binaryURL: URL) -> URL? {
        var candidate = binaryURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    private func sameFileURL(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL.path ==
            rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Sends SIGTERM to the profile's Camoufox process if it is running.
    func terminate(profileID: UUID) {
        guard let launched = runningProfile(id: profileID), launched.isRunning else { return }
        launched.process.terminate()
    }

    // MARK: user.js generation

    private func writeUserJS(for profile: Profile, marionettePort: Int?, proxyRelay: ProxyRelay?) throws {
        var prefs: [String: AnyHashable] = [:]

        if let proxyRelay {
            for (k, v) in profile.proxy.firefoxPrefsForLocalRelay(
                host: proxyRelay.localHost,
                port: proxyRelay.localPort
            ) {
                prefs[k] = v
            }
        } else {
            for (k, v) in profile.proxy.firefoxPrefs {
                prefs[k] = v
            }
        }
        for (k, v) in profile.fingerprint.derivedFirefoxPrefs() {
            prefs[k] = v
        }

        // Disable safe-mode prompt + auto-update so each spawn is silent
        // and reproducible.
        prefs["app.update.auto"] = false
        prefs["app.update.enabled"] = false
        prefs["browser.shell.checkDefaultBrowser"] = false
        prefs["browser.startup.homepage_override.mstone"] = "ignore"
        prefs["browser.theme.content-theme"] = 1
        prefs["browser.theme.toolbar-theme"] = 1
        prefs["extensions.activeThemeID"] = "firefox-compact-light@mozilla.org"
        prefs["layout.css.prefers-color-scheme.content-override"] = 1
        prefs["toolkit.startup.max_resumed_crashes"] = -1
        prefs["ui.systemUsesDarkTheme"] = 0
        prefs["media.peerconnection.ice.default_address_only"] = true
        prefs["media.peerconnection.ice.no_host"] = true
        prefs["media.peerconnection.ice.proxy_only_if_behind_proxy"] = true
        prefs["media.peerconnection.ice.obfuscate_host_addresses"] = true
        prefs["media.peerconnection.ice.obfuscate_host_addresses.blocklist"] = true
        prefs["media.peerconnection.ice.relay_only"] = profile.proxy.isEnabled
        if Localization.isChinese {
            prefs["intl.locale.requested"] = "zh-CN"
            prefs["intl.regional_prefs.use_os_locales"] = true
            prefs["javascript.use_us_english_locale"] = false
        }

        if let port = marionettePort {
            prefs["marionette.enabled"] = true
            prefs["marionette.port"] = port
            prefs["marionette.host"] = "127.0.0.1"
        }

        let lines = prefs
            .sorted { $0.key < $1.key }
            .map { "user_pref(\"\($0.key)\", \(Self.formatPrefValue($0.value)));" }
        let body = lines.joined(separator: "\n") + "\n"

        let url = AppPaths.userJSURL(for: profile)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CamoufoxLauncherError.ioFailure(url, underlying: error)
        }
    }

    private func installProfileLanguagePackIfNeeded(firefoxProfileDir: URL) throws {
        guard Localization.isChinese else { return }

        let sourceURL = AppPaths.downloadsCacheDir
            .appendingPathComponent("langpack-zh-CN@firefox.mozilla.org.xpi")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        let profileExtensionsURL = firefoxProfileDir
            .appendingPathComponent("extensions", isDirectory: true)
        let installedURL = profileExtensionsURL
            .appendingPathComponent("langpack-zh-CN@firefox.mozilla.org.xpi")
        do {
            try FileManager.default.createDirectory(
                at: profileExtensionsURL,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: installedURL.path) ||
                (try? SHA256Hasher.hash(fileAt: installedURL)) != (try? SHA256Hasher.hash(fileAt: sourceURL)) {
                if FileManager.default.fileExists(atPath: installedURL.path) {
                    try FileManager.default.removeItem(at: installedURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: installedURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installedURL.path)
            }
        } catch {
            throw CamoufoxLauncherError.ioFailure(installedURL, underlying: error)
        }
    }

    private func writeUserChromeCSS(firefoxProfileDir: URL) throws {
        let chromeDir = firefoxProfileDir.appendingPathComponent("chrome", isDirectory: true)
        let userChromeURL = chromeDir.appendingPathComponent("userChrome.css")
        let body = """
        /* MultiProfileFingerprintBrowser profile chrome overrides. */
        #TabsToolbar .tabbrowser-tab {
          border-inline-end: 1px solid rgba(80, 80, 90, 0.35) !important;
        }

        #TabsToolbar .tabbrowser-tab:first-of-type {
          border-inline-start: 1px solid rgba(80, 80, 90, 0.25) !important;
        }

        #TabsToolbar .tabbrowser-tab[selected="true"] .tab-background {
          background-color: rgba(255, 255, 255, 0.88) !important;
          box-shadow: inset 0 -2px 0 rgba(36, 99, 235, 0.85) !important;
        }

        #TabsToolbar .tabbrowser-tab:not([selected="true"]):hover .tab-background {
          background-color: rgba(255, 255, 255, 0.46) !important;
        }

        #tabbrowser-tabs {
          border-bottom: 1px solid rgba(80, 80, 90, 0.28) !important;
        }

        """
        do {
            try FileManager.default.createDirectory(at: chromeDir, withIntermediateDirectories: true)
            try body.write(to: userChromeURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: userChromeURL.path)
        } catch {
            throw CamoufoxLauncherError.ioFailure(userChromeURL, underlying: error)
        }
    }

    /// Firefox `user.js` value formatter.
    /// - Bool → `true` / `false`
    /// - Int/Double → bare number
    /// - String → `"..."` with `\` and `"` escaped
    ///
    /// AnyHashable bridges Int and Bool through NSNumber, so `value as? Bool`
    /// succeeds on `Int(0)` and returns `false`. Inspect the concrete base
    /// type instead of relying on conditional casts.
    static func formatPrefValue(_ value: AnyHashable) -> String {
        let base = value.base
        if base is Bool {
            return (base as! Bool) ? "true" : "false"
        }
        if base is Int {
            return String(base as! Int)
        }
        if base is Double {
            return String(base as! Double)
        }
        if let s = base as? String {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return "\"\(base)\""
    }

    private func applyLaunchOverrides(to fingerprint: inout Fingerprint) {
        fingerprint.properties["showcursor"] = .bool(false)
    }

    // MARK: Environment + args

    private func buildEnvironment(fingerprint: Fingerprint) throws -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Strip any inherited CAMOU_CONFIG_* so chunks always start at 1.
        for key in env.keys where key.hasPrefix("CAMOU_CONFIG_") {
            env.removeValue(forKey: key)
        }

        let json = try fingerprint.toCamoufoxJSON()
        for (idx, chunk) in chunkConfig(json, size: configChunkSize).enumerated() {
            env["CAMOU_CONFIG_\(idx + 1)"] = chunk
        }
        return env
    }

    private func buildArguments(firefoxProfileDir: URL, marionettePort: Int?) -> [String] {
        var args = [
            "--profile", firefoxProfileDir.path,
            "--no-remote",
            "--new-instance",
        ]
        if marionettePort != nil {
            args.append("--marionette")
        }
        return args
    }

    /// Splits a string into fixed-character-count chunks. Mirrors the upstream
    /// Python wrapper exactly: `for i in range(0, len(s), n): s[i:i+n]`.
    func chunkConfig(_ s: String, size: Int) -> [String] {
        guard size > 0, !s.isEmpty else { return [s] }
        var chunks: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            chunks.append(String(s[idx..<end]))
            idx = end
        }
        return chunks
    }
}
