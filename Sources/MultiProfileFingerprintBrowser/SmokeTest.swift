import Foundation

/// Phase 1.8 integrated smoke test. Runs end-to-end:
///   1. CamoufoxRuntime.ensureReady (uses cached archive if present)
///   2. Create 3 profiles with different presets
///   3. Launch each via CamoufoxLauncher
///   4. Wait briefly, terminate, verify clean exit
///
/// Triggered by `MPFB_SMOKE=1 swift run MultiProfileFingerprintBrowser`.
enum SmokeTest {
    static func run() {
        AppLogger.info("SmokeTest start")
        do {
            try runtimeCheck()
            try chunkConfigCheck()
            let profiles = try createProfiles()
            try launchAndTerminate(profiles: profiles)
        } catch {
            AppLogger.error("SmokeTest FAILED: \(error.localizedDescription)")
            exit(1)
        }
        AppLogger.info("SmokeTest PASSED")
        exit(0)
    }

    private static func runtimeCheck() throws {
        AppLogger.info("[step] runtime ensureReady")
        let binary = try CamoufoxRuntime.shared.ensureReady()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "Smoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "binary not executable: \(binary.path)"]
            )
        }
        AppLogger.info("[ok] runtime ready -> \(binary.path)")
    }

    private static func chunkConfigCheck() throws {
        AppLogger.info("[step] CAMOU_CONFIG chunking round-trip")
        let payload = String(repeating: "x", count: 32767 * 2 + 100)
        let chunks = CamoufoxLauncher.shared.chunkConfig(payload, size: 32767)
        guard chunks.count == 3 else {
            throw NSError(
                domain: "Smoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "expected 3 chunks, got \(chunks.count)"]
            )
        }
        let reassembled = chunks.joined()
        guard reassembled == payload else {
            throw NSError(
                domain: "Smoke",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "chunk reassembly mismatch"]
            )
        }
        AppLogger.info("[ok] chunking 3-part round-trip identical")
    }

    private static func createProfiles() throws -> [Profile] {
        AppLogger.info("[step] create 3 profiles from different presets")
        try AppPaths.ensureExists()

        let presets = FingerprintPresets.shared.all
        guard presets.count >= 3 else {
            throw NSError(
                domain: "Smoke",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "need 3 presets, found \(presets.count)"]
            )
        }

        var created: [Profile] = []
        for (i, preset) in presets.prefix(3).enumerated() {
            let name = "smoke-\(i + 1)-\(preset.id)"
            // Delete any leftover from prior runs.
            if let existing = ProfileStore.shared.list().first(where: { $0.name == name }) {
                try ProfileStore.shared.delete(id: existing.id)
            }
            let profile = Profile(
                name: name,
                fingerprint: preset.fingerprint(),
                proxy: .direct,
                notes: "Phase 1.8 smoke",
                marionetteEnabled: false,
                presetID: preset.id
            )
            let saved = try ProfileStore.shared.save(profile)
            created.append(saved)
            AppLogger.info("[ok] saved \(saved.name) id=\(saved.id)")
        }
        return created
    }

    private static func launchAndTerminate(profiles: [Profile]) throws {
        AppLogger.info("[step] launch + terminate each profile")
        for profile in profiles {
            let launched = try CamoufoxLauncher.shared.launch(profile)
            AppLogger.info("[ok] launched \(profile.name) pid=\(launched.process.processIdentifier)")
            // Let Firefox boot enough to read the profile dir + user.js.
            Thread.sleep(forTimeInterval: 4.0)

            guard launched.isRunning else {
                throw NSError(
                    domain: "Smoke",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "process exited prematurely: \(profile.name)"]
                )
            }

            // user.js must exist on disk after launch.
            let userJS = AppPaths.userJSURL(for: profile)
            guard FileManager.default.fileExists(atPath: userJS.path) else {
                throw NSError(
                    domain: "Smoke",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "user.js missing for \(profile.name)"]
                )
            }
            AppLogger.info("[ok] user.js present at \(userJS.path)")

            CamoufoxLauncher.shared.terminate(profileID: profile.id)
            // Wait for the OS to actually deliver SIGTERM and Firefox to clean up.
            for _ in 0..<20 {
                if !launched.isRunning { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if launched.isRunning {
                launched.process.interrupt()
                Thread.sleep(forTimeInterval: 1.0)
            }
            AppLogger.info("[ok] terminated \(profile.name) status=\(launched.process.terminationStatus)")
        }
    }
}
