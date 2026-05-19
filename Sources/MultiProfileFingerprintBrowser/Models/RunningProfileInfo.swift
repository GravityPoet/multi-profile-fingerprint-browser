import Foundation

/// UI-safe snapshot of a launched browser process.
struct RunningProfileInfo: Identifiable, Hashable {
    let id: UUID
    let processID: Int32
    let startedAt: Date
    let marionettePort: Int?

    var marionetteHost: String { "127.0.0.1" }

    var marionetteEndpoint: String? {
        guard let port = marionettePort else { return nil }
        return "\(marionetteHost):\(port)"
    }

    func automationEnvironment(for profile: Profile) -> [String: String] {
        var env: [String: String] = [
            "MPFB_PROFILE_ID": profile.id.uuidString,
            "MPFB_PROFILE_NAME": profile.name,
            "MPFB_PROFILE_DIR": AppPaths.profileDir(for: profile).path,
            "MPFB_FIREFOX_PROFILE_DIR": AppPaths.firefoxProfileDir(for: profile).path,
            "MPFB_PROCESS_ID": String(processID),
        ]

        if let port = marionettePort {
            env["MPFB_MARIONETTE_HOST"] = marionetteHost
            env["MPFB_MARIONETTE_PORT"] = String(port)
            env["MPFB_MARIONETTE_ENDPOINT"] = "\(marionetteHost):\(port)"
        }

        return env
    }
}
