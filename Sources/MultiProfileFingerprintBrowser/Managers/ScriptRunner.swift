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

        // Build environment: inherit the full parent environment so scripts
        // see HOME, TMPDIR, LANG, VIRTUAL_ENV, PYTHONPATH, SSL_CERT_FILE, etc.
        // Then overlay MPFB_* variables from the running profile.
        var env = ProcessInfo.processInfo.environment
        for (key, value) in runningInfo.automationEnvironment(for: profile) {
            env[key] = value
        }

        // Resolve script invocation: if the file has a shebang, /usr/bin/env
        // will honour it; otherwise fall back to a sensible interpreter.
        let (executable, arguments) = Self.resolveInvocation(scriptPath: scriptPath)

        // Build process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
                    // Check cancellation BEFORE exit code — a script that
                    // catches SIGTERM and exits 0 should still show Cancelled.
                    if currentRun.status == .stopping || currentRun.status == .cancelled {
                        currentRun.markCancelled()
                    } else if proc.terminationStatus == 0 {
                        currentRun.markSucceeded()
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

        // Register BEFORE process.run() so the termination handler can
        // always find the run, even if the script exits instantly.
        run.markRunning()
        activeRuns[profileID] = run
        processes[profileID] = process

        do {
            try process.run()
        } catch {
            // Launch failed — undo the registration.
            activeRuns.removeValue(forKey: profileID)
            processes.removeValue(forKey: profileID)
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            throw ScriptRunnerError.launchFailed(underlying: error)
        }

        AppLogger.info("Script run \(runID) started for profile \(profileID) script=\(scriptPath)")
        return run
    }

    /// Stop the active script for a profile. Does not terminate the browser.
    /// Marks the run as `stopping` so no new script can start until the
    /// process actually exits. If the process ignores SIGTERM for 5s,
    /// escalates to SIGINT.
    func stop(profileID: UUID) {
        guard let process = processes[profileID], process.isRunning else { return }
        // Mark as stopping first — prevents new starts.
        if var run = activeRuns[profileID], run.status == .running {
            run.markStopping()
            activeRuns[profileID] = run
        }
        process.terminate()
        // Escalate to SIGINT if process ignores SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if let proc = self.processes[profileID], proc.isRunning {
                AppLogger.info("Script for profile \(profileID) ignoring SIGTERM, sending SIGINT")
                proc.interrupt()
            }
        }
    }

    /// Whether a script is actively running (not stopping) for the profile.
    func isRunning(profileID: UUID) -> Bool {
        if let run = activeRuns[profileID] {
            switch run.status {
            case .running, .stopping:
                return processes[profileID]?.isRunning == true
            default:
                return false
            }
        }
        return false
    }

    /// Get the active or last run for a profile.
    func currentOrLastRun(for profileID: UUID) -> ScriptRun? {
        activeRuns[profileID] ?? lastRuns[profileID]
    }

    /// Kill all running script processes. Called on app exit.
    func terminateAll() {
        var toWait: [Process] = []
        for (profileID, process) in processes where process.isRunning {
            process.terminate()
            toWait.append(process)
            if var run = activeRuns[profileID], run.status == .running {
                run.markCancelled()
                activeRuns[profileID] = run
                lastRuns[profileID] = run
            }
        }
        processes.removeAll()
        // Wait briefly for scripts to exit cleanly.
        for proc in toWait {
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    // MARK: Script Invocation

    /// Resolve how to invoke a script file.
    /// If the file has a shebang (#!) line, use `/usr/bin/env <script>`.
    /// Otherwise, pick an interpreter based on file extension.
    private static func resolveInvocation(scriptPath: String) -> (executable: String, arguments: [String]) {
        // Check if the file is already executable.
        let isExecutable = FileManager.default.isExecutableFile(atPath: scriptPath)

        // If executable and has shebang, env will handle it.
        if isExecutable, let data = FileManager.default.contents(atPath: scriptPath),
           let firstLine = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines).first,
           firstLine.hasPrefix("#!") {
            return ("/usr/bin/env", [scriptPath])
        }

        // If executable (even without visible shebang), still try env.
        if isExecutable {
            return ("/usr/bin/env", [scriptPath])
        }

        // Not executable — pick interpreter by extension.
        let ext = URL(fileURLWithPath: scriptPath).pathExtension.lowercased()
        switch ext {
        case "py", "py3":
            return ("/usr/bin/env", ["python3", scriptPath])
        case "rb":
            return ("/usr/bin/env", ["ruby", scriptPath])
        case "pl":
            return ("/usr/bin/env", ["perl", scriptPath])
        case "js":
            return ("/usr/bin/env", ["node", scriptPath])
        case "sh", "bash", "zsh":
            return ("/usr/bin/env", ["bash", scriptPath])
        default:
            // Try env as last resort; it will fail clearly if no interpreter.
            return ("/usr/bin/env", [scriptPath])
        }
    }
}
