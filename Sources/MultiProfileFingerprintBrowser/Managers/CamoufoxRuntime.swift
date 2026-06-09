import Darwin
import Foundation

enum CamoufoxRuntimeError: Error, LocalizedError {
    case unsupportedArchitecture(String)
    case downloadFailed(URL, underlying: Error)
    case unexpectedHTTPStatus(Int, URL)
    case sha256Mismatch(expected: String, actual: String)
    case extractFailed(underlying: Error)
    case binaryMissing(URL)
    case selfTestFailed(String)
    case languagePackInvalid(String)
    case ioFailure(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Camoufox is not yet bundled for architecture: \(arch). v1.2.0 ships arm64 only."
        case .downloadFailed(let url, let err):
            return "Download from \(url.absoluteString) failed: \(err.localizedDescription)"
        case .unexpectedHTTPStatus(let code, let url):
            return "HTTP \(code) from \(url.absoluteString)"
        case .sha256Mismatch(let expected, let actual):
            return "SHA256 mismatch. expected=\(expected) actual=\(actual)"
        case .extractFailed(let err):
            return "Extract failed: \(err.localizedDescription)"
        case .binaryMissing(let url):
            return "Camoufox binary missing after extract at \(url.path)"
        case .selfTestFailed(let message):
            return "Camoufox privacy self-test failed: \(message)"
        case .languagePackInvalid(let message):
            return "Camoufox language pack is invalid: \(message)"
        case .ioFailure(let url, let err):
            return "I/O failure at \(url.path): \(err.localizedDescription)"
        }
    }
}

/// One immutable release descriptor. Lookup keyed by host CPU arch.
struct CamoufoxRelease {
    let version: String
    let arch: String
    let downloadURL: URL
    let sha256: String
    /// Filename inside the cache + name of the extracted directory.
    let archiveFilename: String
    /// Path inside the extracted directory to the Camoufox executable.
    let binarySubpath: String
}

extension CamoufoxRelease {
    static let macArm64 = CamoufoxRelease(
        version: "150.0.2-beta.25",
        arch: "arm64",
        downloadURL: URL(string: "https://github.com/daijro/camoufox/releases/download/v150.0.2-beta.25/camoufox-150.0.2-alpha.25-mac.arm64.zip")!,
        sha256: "a7f03c1def1ad63029b0d522353039e88afadbdef2517755b733e6931a462eb2",
        archiveFilename: "camoufox-150.0.2-beta.25-mac.arm64.zip",
        binarySubpath: "Camoufox.app/Contents/MacOS/camoufox"
    )

    static func current() throws -> CamoufoxRelease {
        let arch = CamoufoxRuntime.hostArchitecture()
        switch arch {
        case "arm64":
            return .macArm64
        default:
            throw CamoufoxRuntimeError.unsupportedArchitecture(arch)
        }
    }
}

/// Camoufox runtime status, observable by UI.
enum CamoufoxRuntimeStatus: Equatable {
    case notReady
    case downloading(progress: Double)
    case verifying
    case extracting
    case ready(URL)
    case failed(String)
}

/// Manages the on-disk Camoufox binary used to launch profiles.
/// Idempotent: re-running `ensureReady()` after a successful install is a no-op
/// other than verifying the binary still exists.
final class CamoufoxRuntime {
    static let shared = CamoufoxRuntime()

    private let zhCNLanguagePackURL = URL(
        string: "https://addons.mozilla.org/firefox/downloads/file/4801623/chinese_simplified_zh_cn_la-150.0.20260511.200624.xpi"
    )!
    private let zhCNLanguagePackID = "langpack-zh-CN@firefox.mozilla.org"
    private let zhCNLanguagePackFilename = "langpack-zh-CN@firefox.mozilla.org.xpi"

    private(set) var status: CamoufoxRuntimeStatus = .notReady {
        didSet {
            AppLogger.debug("CamoufoxRuntime status -> \(status)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusListeners.forEach { $0(self.status) }
            }
        }
    }
    private var statusListeners: [(CamoufoxRuntimeStatus) -> Void] = []

    private init() {}

    // MARK: Public API

    /// Adds a status listener. Called on the main queue.
    func observe(_ listener: @escaping (CamoufoxRuntimeStatus) -> Void) {
        statusListeners.append(listener)
        listener(status)
    }

    /// Returns the path to the ready Camoufox binary.
    /// Downloads + verifies + extracts on first call.
    /// Subsequent calls return immediately if the binary is present.
    @discardableResult
    func ensureReady() throws -> URL {
        let release = try CamoufoxRelease.current()
        let binaryURL = expectedBinaryURL(for: release)

        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            try ensureChineseLanguagePackIfNeeded(binaryURL: binaryURL)
            try runPrivacySelfTest(binaryURL: binaryURL, release: release)
            status = .ready(binaryURL)
            return binaryURL
        }

        try AppPaths.ensureExists()
        let archiveURL = AppPaths.downloadsCacheDir.appendingPathComponent(release.archiveFilename)

        try downloadIfNeeded(release: release, to: archiveURL)
        try verify(archive: archiveURL, expected: release.sha256)
        try extract(release: release, archive: archiveURL)

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw CamoufoxRuntimeError.binaryMissing(binaryURL)
        }

        try ensureChineseLanguagePackIfNeeded(binaryURL: binaryURL)
        try runPrivacySelfTest(binaryURL: binaryURL, release: release)
        status = .ready(binaryURL)
        AppLogger.info("Camoufox runtime ready at \(binaryURL.path)")
        return binaryURL
    }

    func expectedBinaryURL(for release: CamoufoxRelease) -> URL {
        extractedDir(for: release).appendingPathComponent(release.binarySubpath)
    }

    func extractedDir(for release: CamoufoxRelease) -> URL {
        AppPaths.runtimeDir.appendingPathComponent("camoufox-\(release.version)-\(release.arch)", isDirectory: true)
    }

    // MARK: Steps

    private func downloadIfNeeded(release: CamoufoxRelease, to archiveURL: URL) throws {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            AppLogger.info("Using cached Camoufox archive at \(archiveURL.path)")
            return
        }
        status = .downloading(progress: 0)
        AppLogger.info("Downloading Camoufox from \(release.downloadURL.absoluteString)")

        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?
        var capturedTempURL: URL?
        var capturedResponse: URLResponse?

        let task = URLSession.shared.downloadTask(with: release.downloadURL) { tempURL, response, error in
            capturedTempURL = tempURL
            capturedResponse = response
            capturedError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = capturedError {
            throw CamoufoxRuntimeError.downloadFailed(release.downloadURL, underlying: error)
        }
        if let http = capturedResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CamoufoxRuntimeError.unexpectedHTTPStatus(http.statusCode, release.downloadURL)
        }
        guard let tempURL = capturedTempURL else {
            throw CamoufoxRuntimeError.downloadFailed(
                release.downloadURL,
                underlying: NSError(domain: "CamoufoxRuntime", code: -1)
            )
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: archiveURL)
        } catch {
            throw CamoufoxRuntimeError.ioFailure(archiveURL, underlying: error)
        }
    }

    private func verify(archive: URL, expected: String) throws {
        status = .verifying
        let actual = try SHA256Hasher.hash(fileAt: archive)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            try? FileManager.default.removeItem(at: archive)
            throw CamoufoxRuntimeError.sha256Mismatch(expected: expected, actual: actual)
        }
        AppLogger.info("Camoufox archive SHA256 verified")
    }

    private func extract(release: CamoufoxRelease, archive: URL) throws {
        status = .extracting
        let destDir = extractedDir(for: release)
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }
        do {
            try ZipExtractor.unzip(archive, into: destDir)
        } catch {
            throw CamoufoxRuntimeError.extractFailed(underlying: error)
        }
        AppLogger.info("Camoufox extracted into \(destDir.path)")
    }

    private func runPrivacySelfTest(binaryURL: URL, release: CamoufoxRelease) throws {
        status = .verifying
        do {
            try PrivacySelfTestRunner.ensurePassed(binaryURL: binaryURL, release: release)
        } catch {
            status = .failed(error.localizedDescription)
            throw CamoufoxRuntimeError.selfTestFailed(error.localizedDescription)
        }
    }

    private func ensureChineseLanguagePackIfNeeded(binaryURL: URL) throws {
        guard Localization.isChinese else { return }

        let resourcesURL = camoufoxResourcesURL(for: binaryURL)
        let extensionsURL = resourcesURL
            .appendingPathComponent("distribution", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        let installedURL = extensionsURL.appendingPathComponent(zhCNLanguagePackFilename)

        try FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        let cachedURL = AppPaths.downloadsCacheDir.appendingPathComponent(zhCNLanguagePackFilename)
        try downloadChineseLanguagePackIfNeeded(to: cachedURL)
        try validateChineseLanguagePack(cachedURL)

        if !FileManager.default.fileExists(atPath: installedURL.path) ||
            (try? SHA256Hasher.hash(fileAt: installedURL)) != (try? SHA256Hasher.hash(fileAt: cachedURL)) {
            if FileManager.default.fileExists(atPath: installedURL.path) {
                try FileManager.default.removeItem(at: installedURL)
            }
            try FileManager.default.copyItem(at: cachedURL, to: installedURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installedURL.path)
            AppLogger.info("Installed zh-CN language pack into \(installedURL.path)")
        }

        try writeChineseLocalePolicy(resourcesURL: resourcesURL)
    }

    private func camoufoxResourcesURL(for binaryURL: URL) -> URL {
        binaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private func downloadChineseLanguagePackIfNeeded(to destinationURL: URL) throws {
        try AppPaths.ensureExists()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }

        AppLogger.info("Downloading Firefox zh-CN language pack from \(zhCNLanguagePackURL.absoluteString)")
        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?
        var capturedTempURL: URL?
        var capturedResponse: URLResponse?

        let task = URLSession.shared.downloadTask(with: zhCNLanguagePackURL) { tempURL, response, error in
            capturedTempURL = tempURL
            capturedResponse = response
            capturedError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = capturedError {
            throw CamoufoxRuntimeError.downloadFailed(zhCNLanguagePackURL, underlying: error)
        }
        if let http = capturedResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CamoufoxRuntimeError.unexpectedHTTPStatus(http.statusCode, zhCNLanguagePackURL)
        }
        guard let tempURL = capturedTempURL else {
            throw CamoufoxRuntimeError.downloadFailed(
                zhCNLanguagePackURL,
                underlying: NSError(domain: "CamoufoxRuntime", code: -2)
            )
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destinationURL.path)
        } catch {
            throw CamoufoxRuntimeError.ioFailure(destinationURL, underlying: error)
        }
    }

    private func validateChineseLanguagePack(_ url: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "manifest.json"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CamoufoxRuntimeError.ioFailure(url, underlying: error)
        }

        guard process.terminationStatus == 0 else {
            throw CamoufoxRuntimeError.languagePackInvalid("manifest.json not readable")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            manifest["langpack_id"] as? String == "zh-CN",
            let settings = manifest["browser_specific_settings"] as? [String: Any],
            let gecko = settings["gecko"] as? [String: Any],
            gecko["id"] as? String == zhCNLanguagePackID,
            gecko["strict_min_version"] as? String == "150.0",
            gecko["strict_max_version"] as? String == "150.*"
        else {
            throw CamoufoxRuntimeError.languagePackInvalid("unexpected manifest metadata")
        }
    }

    private func writeChineseLocalePolicy(resourcesURL: URL) throws {
        let distributionURL = resourcesURL.appendingPathComponent("distribution", isDirectory: true)
        let policiesURL = distributionURL.appendingPathComponent("policies.json")
        try FileManager.default.createDirectory(at: distributionURL, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: policiesURL.path) {
            let data = try Data(contentsOf: policiesURL)
            root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        var policies = (root["policies"] as? [String: Any]) ?? [:]
        policies["RequestedLocales"] = ["zh-CN"]
        var extensionSettings = (policies["ExtensionSettings"] as? [String: Any]) ?? [:]
        extensionSettings[zhCNLanguagePackID] = [
            "installation_mode": "force_installed",
            "install_url": installedLanguagePackURL(resourcesURL: resourcesURL).absoluteString,
            "updates_disabled": true,
        ]
        policies["ExtensionSettings"] = extensionSettings
        root["policies"] = policies

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        do {
            try data.write(to: policiesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: policiesURL.path)
        } catch {
            throw CamoufoxRuntimeError.ioFailure(policiesURL, underlying: error)
        }
    }

    private func installedLanguagePackURL(resourcesURL: URL) -> URL {
        resourcesURL
            .appendingPathComponent("distribution", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(zhCNLanguagePackFilename)
    }

    // MARK: Host architecture

    static func hostArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let arch = withUnsafePointer(to: &info.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cstr in
                String(cString: cstr)
            }
        }
        return arch
    }
}
