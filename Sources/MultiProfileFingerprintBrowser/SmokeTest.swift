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
            try marionetteLaunchCheck()
            try scriptRunnerCheck()
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

    private static func marionetteLaunchCheck() throws {
        AppLogger.info("[step] marionette launch check")
        guard let preset = FingerprintPresets.shared.all.first else {
            throw NSError(
                domain: "Smoke",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "need one preset for marionette check"]
            )
        }

        let name = "smoke-marionette-\(preset.id)"
        if let existing = ProfileStore.shared.list().first(where: { $0.name == name }) {
            try ProfileStore.shared.delete(id: existing.id)
        }

        let profile = try ProfileStore.shared.save(Profile(
            name: name,
            fingerprint: preset.fingerprint(),
            proxy: .direct,
            notes: "Phase automation smoke",
            marionetteEnabled: true,
            presetID: preset.id
        ))

        let launched = try CamoufoxLauncher.shared.launch(profile)
        defer {
            CamoufoxLauncher.shared.terminate(profileID: profile.id)
        }

        guard let port = launched.marionettePort else {
            throw NSError(
                domain: "Smoke",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "marionette port was not allocated"]
            )
        }

        Thread.sleep(forTimeInterval: 2.0)

        let userJS = AppPaths.userJSURL(for: profile)
        let body = try String(contentsOf: userJS, encoding: .utf8)
        guard body.contains("user_pref(\"marionette.enabled\", true);"),
              body.contains("user_pref(\"marionette.port\", \(port));") else {
            throw NSError(
                domain: "Smoke",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "marionette prefs missing from user.js"]
            )
        }

        let snapshot = RunningProfileInfo(
            id: launched.profileID,
            processID: launched.process.processIdentifier,
            startedAt: launched.startedAt,
            marionettePort: port
        )
        let env = snapshot.automationEnvironment(for: profile)
        guard env["MPFB_MARIONETTE_ENDPOINT"] == "127.0.0.1:\(port)" else {
            throw NSError(
                domain: "Smoke",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "automation env endpoint mismatch"]
            )
        }

        AppLogger.info("[ok] marionette endpoint 127.0.0.1:\(port)")
    }

    private static func scriptRunnerCheck() throws {
        AppLogger.info("[step] script runner env injection check")
        guard let preset = FingerprintPresets.shared.all.first else {
            throw NSError(
                domain: "Smoke",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "need one preset for script runner check"]
            )
        }

        let name = "smoke-script-runner-\(preset.id)"
        if let existing = ProfileStore.shared.list().first(where: { $0.name == name }) {
            try ProfileStore.shared.delete(id: existing.id)
        }

        let profile = try ProfileStore.shared.save(Profile(
            name: name,
            fingerprint: preset.fingerprint(),
            proxy: .direct,
            notes: "Script runner smoke",
            marionetteEnabled: true,
            presetID: preset.id
        ))

        let launched = try CamoufoxLauncher.shared.launch(profile)
        defer {
            ScriptRunner.shared.terminateAll()
            CamoufoxLauncher.shared.terminate(profileID: profile.id)
        }

        guard let port = launched.marionettePort else {
            throw NSError(
                domain: "Smoke",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "marionette port not allocated for script runner"]
            )
        }

        Thread.sleep(forTimeInterval: 2.0)

        let runningInfo = RunningProfileInfo(
            id: launched.profileID,
            processID: launched.process.processIdentifier,
            startedAt: launched.startedAt,
            marionettePort: port
        )

        // Test 1: success script that prints env vars.
        let automationDir = AppPaths.logsDir
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: automationDir,
            withIntermediateDirectories: true
        )
        let successScript = automationDir.appendingPathComponent("smoke-success.sh")
        try """
        #!/bin/bash
        echo "MPFB_PROFILE_ID=$MPFB_PROFILE_ID"
        echo "MPFB_MARIONETTE_ENDPOINT=$MPFB_MARIONETTE_ENDPOINT"
        exit 0
        """.write(to: successScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: successScript.path
        )

        _ = try ScriptRunner.shared.start(
            scriptPath: successScript.path,
            profile: profile,
            runningInfo: runningInfo
        )

        // Wait for completion.
        for _ in 0..<20 {
            if ScriptRunner.shared.currentOrLastRun(for: profile.id)?.isTerminal == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let completedRun = ScriptRunner.shared.currentOrLastRun(for: profile.id)
        guard let run = completedRun, run.isTerminal else {
            throw NSError(
                domain: "Smoke",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "success script did not complete in time"]
            )
        }
        guard run.status == .succeeded else {
            throw NSError(
                domain: "Smoke",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "success script failed: exit=\(run.exitCode ?? -1)"]
            )
        }

        let stdout = FileManager.default.contents(atPath: run.stdoutLogPath).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        guard stdout.contains("MPFB_PROFILE_ID=\(profile.id.uuidString)"),
              stdout.contains("MPFB_MARIONETTE_ENDPOINT=127.0.0.1:\(port)") else {
            throw NSError(
                domain: "Smoke",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "env injection mismatch: \(stdout)"]
            )
        }
        AppLogger.info("[ok] success script env injection verified")

        // Test 2: failing script (exit 42).
        let failScript = automationDir.appendingPathComponent("smoke-fail.sh")
        try """
        #!/bin/bash
        echo "intentional failure" >&2
        exit 42
        """.write(to: failScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: failScript.path
        )

        _ = try ScriptRunner.shared.start(
            scriptPath: failScript.path,
            profile: profile,
            runningInfo: runningInfo
        )

        for _ in 0..<20 {
            if ScriptRunner.shared.currentOrLastRun(for: profile.id)?.isTerminal == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        guard let failRun = ScriptRunner.shared.currentOrLastRun(for: profile.id),
              failRun.isTerminal else {
            throw NSError(
                domain: "Smoke",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "fail script did not complete in time"]
            )
        }
        guard failRun.status == .failed, failRun.exitCode == 42 else {
            throw NSError(
                domain: "Smoke",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "expected exit 42, got \(failRun.exitCode ?? -1)"]
            )
        }

        let stderr = FileManager.default.contents(atPath: failRun.stderrLogPath).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        guard stderr.contains("intentional failure") else {
            throw NSError(
                domain: "Smoke",
                code: 18,
                userInfo: [NSLocalizedDescriptionKey: "stderr missing expected content"]
            )
        }
        AppLogger.info("[ok] fail script exit=42 stderr captured")
    }
}
