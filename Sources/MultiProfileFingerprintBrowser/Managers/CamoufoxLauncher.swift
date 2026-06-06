import Foundation

enum CamoufoxLauncherError: Error, LocalizedError {
    case runtimeNotReady
    case alreadyRunning(UUID)
    case spawnFailed(underlying: Error)
    case ioFailure(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady:
            return "Camoufox runtime is not ready yet. Download the runtime first."
        case .alreadyRunning(let id):
            return "Profile \(id.uuidString) is already running"
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
    let startedAt: Date

    init(profileID: UUID, process: Process, marionettePort: Int?, startedAt: Date) {
        self.profileID = profileID
        self.process = process
        self.marionettePort = marionettePort
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
        let snapshot = listeners
        DispatchQueue.main.async { snapshot.forEach { $0() } }
    }

    // MARK: Launch / Terminate

    /// Launches Camoufox for the given profile. Throws if the runtime is not
    /// downloaded, if the profile is already running, or if the process
    /// fails to spawn.
    /// - Parameter geo: Optional geolocation info resolved from proxy exit IP.
    ///   When provided, injects concrete timezone so it matches the exit region.
    @discardableResult
    func launch(_ profile: Profile, geo: ProxyGeoResolver.GeoInfo? = nil) throws -> LaunchedProfile {
        if let existing = runningProfile(id: profile.id), existing.isRunning {
            throw CamoufoxLauncherError.alreadyRunning(profile.id)
        }

        let binaryURL = try CamoufoxRuntime.shared.ensureReady()

        let firefoxProfileDir = AppPaths.firefoxProfileDir(for: profile)
        do {
            try FileManager.default.createDirectory(
                at: firefoxProfileDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw CamoufoxLauncherError.ioFailure(firefoxProfileDir, underlying: error)
        }

        var marionettePort: Int? = nil
        if profile.marionetteEnabled {
            marionettePort = try PortAllocator.shared.allocate()
        }

        try writeUserJS(
            for: profile,
            marionettePort: marionettePort
        )

        // Inject timezone that matches the proxy exit IP.
        // The Camoufox binary accepts concrete timezone via the "timezone" key
        // (verified: old presets used it). The "geoip" key is a Python wrapper
        // feature — the binary ignores it, so we resolve the timezone ourselves.
        var fingerprint = profile.fingerprint
        if profile.proxy.isEnabled {
            // Remove the no-op geoip key if set by old code.
            fingerprint.geoip = nil
            if let geo {
                // Concrete timezone from proxy exit IP — the gold standard.
                fingerprint.timezone = geo.timezone
                AppLogger.info("Injected timezone from proxy geo: \(geo.timezone)")
            } else if fingerprint.timezone == nil || fingerprint.timezone?.isEmpty == true {
                // No geo resolved and no timezone set — use UTC as safe fallback.
                // Better to be "UTC user" than "timezone leaks real location".
                fingerprint.timezone = "UTC"
                AppLogger.warn("No proxy geo; falling back to UTC timezone")
            }
            // If fingerprint already has a timezone (from preset), keep it —
            // user chose that preset knowing their proxy region.
        }

        let env = try buildEnvironment(fingerprint: fingerprint)
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
            }
            self.notifyChange()
        }

        do {
            try process.run()
        } catch {
            if let port = marionettePort {
                PortAllocator.shared.release(port)
            }
            throw CamoufoxLauncherError.spawnFailed(underlying: error)
        }

        let launched = LaunchedProfile(
            profileID: profile.id,
            process: process,
            marionettePort: marionettePort,
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

    /// Sends SIGTERM to the profile's Camoufox process if it is running.
    func terminate(profileID: UUID) {
        guard let launched = runningProfile(id: profileID), launched.isRunning else { return }
        launched.process.terminate()
    }

    // MARK: user.js generation

    private func writeUserJS(for profile: Profile, marionettePort: Int?) throws {
        var prefs: [String: AnyHashable] = [:]

        for (k, v) in profile.proxy.firefoxPrefs {
            prefs[k] = v
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
        prefs["toolkit.startup.max_resumed_crashes"] = -1

        if let port = marionettePort {
            prefs["marionette.enabled"] = true
            prefs["marionette.port"] = port
        }

        let lines = prefs
            .sorted { $0.key < $1.key }
            .map { "user_pref(\"\($0.key)\", \(Self.formatPrefValue($0.value)));" }
        let body = lines.joined(separator: "\n") + "\n"

        let url = AppPaths.userJSURL(for: profile)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CamoufoxLauncherError.ioFailure(url, underlying: error)
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
