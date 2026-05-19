import Foundation

enum ScriptRunnerError: Error, LocalizedError {
    case profileNotRunning(UUID)
    case alreadyRunning(UUID)
    case scriptNotFound(String)
    case launchFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .profileNotRunning(let id):
            return "Profile \(id.uuidString) is not running. Launch it first."
        case .alreadyRunning(let id):
            return "A script is already running for profile \(id.uuidString). Stop it first."
        case .scriptNotFound(let path):
            return "Script not found at \(path)"
        case .launchFailed(let err):
            return "Failed to launch script: \(err.localizedDescription)"
        }
    }
}

/// Manages script execution against running browser profiles.
/// One active script per profile. Scripts run as child processes with
/// MPFB_* environment variables injected. stdout/stderr are captured
/// to log files under `logs/automation/<run-id>/`.
final class ScriptRunner: ObservableObject {
    static let shared = ScriptRunner()

    @Published private(set) var activeRuns: [UUID: ScriptRun] = [:]
    @Published private(set) var lastRuns: [UUID: ScriptRun] = [:]

    private var processes: [UUID: Process] = [:]

    private init() {}

    // MARK: Public API

    /// Start a script for the given profile. The profile must be running.
    func start(scriptPath: String, profile: Profile, runningInfo: RunningProfileInfo) throws -> ScriptRun {
        let profileID = profile.id

        // Check profile is running.
        guard CamoufoxLauncher.shared.runningProfile(id: profileID)?.isRunning == true else {
            throw ScriptRunnerError.profileNotRunning(profileID)
        }

        // Check no active run for this profile.
        if let existing = activeRuns[profileID], !existing.isTerminal {
            throw ScriptRunnerError.alreadyRunning(profileID)
        }

        // Check script exists.
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ScriptRunnerError.scriptNotFound(scriptPath)
        }

        // Prepare log directory.
        let runID = UUID()
        let logDir = AppPaths.logsDir
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let stdoutLog = logDir.appendingPathComponent("stdout.log").path
        let stderrLog = logDir.appendingPathComponent("stderr.log").path

        // Create empty log files.
        FileManager.default.createFile(atPath: stdoutLog, contents: nil)
        FileManager.default.createFile(atPath: stderrLog, contents: nil)

        var run = ScriptRun(
            id: runID,
            profileID: profileID,
            scriptPath: scriptPath,
            stdoutLogPath: stdoutLog,
            stderrLogPath: stderrLog
        )

        // Build environment.
        var env = runningInfo.automationEnvironment(for: profile)
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin"

        // Build process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [scriptPath]
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()

        // Redirect stdout/stderr to log files.
        let stdoutHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutLog))
        let stderrHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrLog))
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        // Termination handler.
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                stdoutHandle.closeFile()
                stderrHandle.closeFile()

                if var currentRun = self.activeRuns[profileID], currentRun.id == runID {
                    if proc.terminationStatus == 0 {
                        currentRun.markSucceeded()
                    } else if currentRun.status == .cancelled {
                        // Already marked cancelled.
                    } else {
                        currentRun.markFailed(exitCode: proc.terminationStatus)
                    }
                    self.activeRuns[profileID] = currentRun
                    self.lastRuns[profileID] = currentRun
                    self.processes.removeValue(forKey: profileID)
                    AppLogger.info(
                        "Script run \(runID) finished for profile \(profileID) exit=\(proc.terminationStatus)"
                    )
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            throw ScriptRunnerError.launchFailed(underlying: error)
        }

        run.markRunning()
        activeRuns[profileID] = run
        processes[profileID] = process

        AppLogger.info("Script run \(runID) started for profile \(profileID) script=\(scriptPath)")
        return run
    }

    /// Stop the active script for a profile. Does not terminate the browser.
    func stop(profileID: UUID) {
        guard let process = processes[profileID], process.isRunning else { return }
        process.terminate()
        if var run = activeRuns[profileID], run.status == .running {
            run.markCancelled()
            activeRuns[profileID] = run
            lastRuns[profileID] = run
        }
    }

    /// Whether a script is currently running for the profile.
    func isRunning(profileID: UUID) -> Bool {
        if let run = activeRuns[profileID], run.status == .running {
            return processes[profileID]?.isRunning == true
        }
        return false
    }

    /// Get the active or last run for a profile.
    func currentOrLastRun(for profileID: UUID) -> ScriptRun? {
        activeRuns[profileID] ?? lastRuns[profileID]
    }

    /// Kill all running script processes. Called on app exit.
    func terminateAll() {
        for (profileID, process) in processes where process.isRunning {
            process.terminate()
            if var run = activeRuns[profileID], run.status == .running {
                run.markCancelled()
                activeRuns[profileID] = run
                lastRuns[profileID] = run
            }
        }
        processes.removeAll()
    }
}
