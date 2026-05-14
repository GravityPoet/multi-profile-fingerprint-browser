import Foundation

enum AppPaths {
    static let appName = "MultiProfileFingerprintBrowser"

    static var supportRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var profilesDir: URL {
        supportRoot.appendingPathComponent("profiles", isDirectory: true)
    }

    static var runtimeDir: URL {
        supportRoot.appendingPathComponent("runtime", isDirectory: true)
    }

    static var downloadsCacheDir: URL {
        supportRoot.appendingPathComponent("downloads", isDirectory: true)
    }

    static var logsDir: URL {
        supportRoot.appendingPathComponent("logs", isDirectory: true)
    }

    static func profileDir(for profile: Profile) -> URL {
        profilesDir.appendingPathComponent(profile.directoryName, isDirectory: true)
    }

    static func profileMetaURL(for profile: Profile) -> URL {
        profileDir(for: profile).appendingPathComponent("meta.json")
    }

    static func firefoxProfileDir(for profile: Profile) -> URL {
        profileDir(for: profile).appendingPathComponent("firefox-profile", isDirectory: true)
    }

    static func userJSURL(for profile: Profile) -> URL {
        firefoxProfileDir(for: profile).appendingPathComponent("user.js")
    }

    /// Create the root + standard subdirectories if missing.
    static func ensureExists() throws {
        let dirs = [supportRoot, profilesDir, runtimeDir, downloadsCacheDir, logsDir]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
