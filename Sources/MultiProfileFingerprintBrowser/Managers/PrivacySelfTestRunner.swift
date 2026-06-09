import Foundation

enum PrivacySelfTestError: Error, LocalizedError {
    case timeout(String)
    case launchFailed(Error)
    case failed([String])

    var errorDescription: String? {
        switch self {
        case .timeout(let role):
            return "privacy self-test timed out waiting for \(role)"
        case .launchFailed(let error):
            return "privacy self-test launch failed: \(error.localizedDescription)"
        case .failed(let failures):
            return "privacy self-test failed:\n" + failures.joined(separator: "\n")
        }
    }
}

struct PrivacySelfTestReport: Codable {
    let version: String
    let binaryHash: String
    let ts: Date
    let failures: [String]
    let a: ProbeResult
    let b: ProbeResult
}

struct ProbeResult: Codable {
    struct Signal: Codable {
        let timezone: String?
        let language: String?
        let languages: [String]?
        let platform: String?
        let hardwareConcurrency: Int?
        let deviceMemory: Int?
        let webdriver: Bool?
        let userAgent: String?
        let error: String?
    }
    struct Storage: Codable {
        let cookie: String?
        let local: String?
        let idb: String?
        let cache: Bool?
    }
    struct WebGL: Codable {
        let vendor: String?
        let renderer: String?
        let error: String?
    }
    let role: String
    let main: Signal?
    let worker: Signal?
    let iframe: Signal?
    let serviceWorker: Signal?
    let webgl: WebGL?
    let canvas: String?
    let audio: String?
    let webrtc: [String]?
    let storageBefore: Storage?
    let error: String?
}

enum PrivacySelfTestRunner {
    static func stampURL(version: String, binaryHash: String) -> URL {
        AppPaths.selfTestDir.appendingPathComponent("selftest-\(version)-\(binaryHash.prefix(12)).json")
    }

    static func ensurePassed(binaryURL: URL, release: CamoufoxRelease) throws {
        try AppPaths.ensureExists()
        let hash = try SHA256Hasher.hash(fileAt: binaryURL)
        let stamp = stampURL(version: release.version, binaryHash: hash)
        if FileManager.default.fileExists(atPath: stamp.path) {
            AppLogger.info("Privacy self-test stamp exists: \(stamp.path)")
            return
        }
        let report = try run(binaryURL: binaryURL, release: release, binaryHash: hash)
        let data = try JSONEncoder.prettyISO.encode(report)
        try data.write(to: stamp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stamp.path)
    }

    static func run(binaryURL: URL, release: CamoufoxRelease, binaryHash: String) throws -> PrivacySelfTestReport {
        let server = try PrivacyProbeServer()
        defer { server.stop() }
        let preset = FingerprintDeriver.defaultPreset()
        let seedA = Profile.makeFingerprintSeed()
        var seedB = Profile.makeFingerprintSeed()
        if seedB == seedA { seedB = seedB &+ 1 }
        let fpA = FingerprintDeriver.derive(from: preset, seed: seedA)
        let fpB = FingerprintDeriver.derive(from: preset, seed: seedB)

        let procA = try launchProbe(binaryURL: binaryURL, role: "a", url: server.url(role: "a"), fingerprint: fpA)
        defer { terminate(procA.process); cleanup(procA.dir) }
        let a = try waitResult(server: server, role: "a")
        terminate(procA.process)
        cleanup(procA.dir)

        let procB = try launchProbe(binaryURL: binaryURL, role: "b", url: server.url(role: "b"), fingerprint: fpB)
        defer { terminate(procB.process); cleanup(procB.dir) }
        let b = try waitResult(server: server, role: "b")

        let failures = evaluate(a: a, b: b, expectedA: fpA, expectedB: fpB)
        let report = PrivacySelfTestReport(
            version: release.version,
            binaryHash: binaryHash,
            ts: Date(),
            failures: failures,
            a: a,
            b: b
        )
        if !failures.isEmpty {
            throw PrivacySelfTestError.failed(failures)
        }
        AppLogger.info("Privacy self-test passed for Camoufox \(release.version)")
        return report
    }

    private static func launchProbe(binaryURL: URL, role: String, url: String, fingerprint: Fingerprint) throws -> (process: Process, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpfb-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let userJS = dir.appendingPathComponent("user.js")
        let prefs = [
            "media.peerconnection.ice.default_address_only": true,
            "media.peerconnection.ice.no_host": true,
            "media.peerconnection.ice.proxy_only_if_behind_proxy": true,
            "media.peerconnection.ice.obfuscate_host_addresses": true,
            "media.peerconnection.ice.obfuscate_host_addresses.blocklist": true,
            "browser.shell.checkDefaultBrowser": false,
            "browser.startup.homepage_override.mstone": "ignore",
        ] as [String: AnyHashable]
        let body = prefs.sorted { $0.key < $1.key }
            .map { "user_pref(\"\($0.key)\", \(CamoufoxLauncher.formatPrefValue($0.value)));" }
            .joined(separator: "\n") + "\n"
        try body.write(to: userJS, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userJS.path)

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--profile", dir.path, "--no-remote", "--new-instance", "--headless", url]
        proc.environment = try environment(fingerprint: fingerprint)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            return (proc, dir)
        } catch {
            throw PrivacySelfTestError.launchFailed(error)
        }
    }

    private static func waitResult(server: PrivacyProbeServer, role: String) throws -> ProbeResult {
        for _ in 0..<80 {
            if let data = server.result(role: role) {
                return try JSONDecoder().decode(ProbeResult.self, from: data)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw PrivacySelfTestError.timeout(role)
    }

    private static func environment(fingerprint: Fingerprint) throws -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CAMOU_CONFIG_") {
            env.removeValue(forKey: key)
        }
        let json = try fingerprint.toCamoufoxJSON()
        let chunks = CamoufoxLauncher.shared.chunkConfig(json, size: 32767)
        for (idx, chunk) in chunks.enumerated() {
            env["CAMOU_CONFIG_\(idx + 1)"] = chunk
        }
        return env
    }

    private static func evaluate(a: ProbeResult, b: ProbeResult, expectedA: Fingerprint, expectedB: Fingerprint) -> [String] {
        var failures: [String] = []
        for r in [a, b] {
            if let error = r.error { failures.append("\(r.role): probe error \(error)") }
            if r.main?.webdriver == true { failures.append("\(r.role): navigator.webdriver is true") }
            if r.main?.timezone == nil || r.worker?.timezone != r.main?.timezone || r.iframe?.timezone != r.main?.timezone {
                failures.append("\(r.role): main/worker/iframe timezone mismatch")
            }
            if let swError = r.serviceWorker?.error {
                failures.append("\(r.role): service worker signal failed: \(swError)")
            }
            if let ips = r.webrtc {
                let leaks = ips.filter { isPrivateV4($0) || isLinkLocalV6($0) }
                if !leaks.isEmpty { failures.append("\(r.role): WebRTC local/private IP leak \(leaks)") }
            } else {
                failures.append("\(r.role): missing WebRTC result")
            }
            if r.canvas == nil || r.audio == nil || r.webgl == nil {
                failures.append("\(r.role): missing canvas/audio/WebGL result")
            }
        }
        if a.canvas == b.canvas {
            failures.append("pair: canvas hashes did not differ")
        }
        if a.audio == b.audio {
            failures.append("pair: audio hashes did not differ")
        }
        if storageHasMarker(b.storageBefore) {
            failures.append("pair: B profile could read A cookie/localStorage/IndexedDB/cache marker")
        }
        if expectedA.stableID == expectedB.stableID {
            failures.append("pair: derived fingerprints have identical stableID")
        }
        return failures
    }

    private static func storageHasMarker(_ storage: ProbeResult.Storage?) -> Bool {
        guard let storage else { return false }
        return (storage.cookie ?? "").contains("mpfb_marker=A")
            || storage.local == "A"
            || storage.idb == "A"
            || storage.cache == true
    }

    private static func isPrivateV4(_ ip: String) -> Bool {
        ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.")
            || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
    }

    private static func isLinkLocalV6(_ ip: String) -> Bool {
        ip.lowercased().hasPrefix("fe80") || ip.lowercased().hasPrefix("fc") || ip.lowercased().hasPrefix("fd")
    }

    private static func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.interrupt()
        }
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}

private extension JSONEncoder {
    static var prettyISO: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
