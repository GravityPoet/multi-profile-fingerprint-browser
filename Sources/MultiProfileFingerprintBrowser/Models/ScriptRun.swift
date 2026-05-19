import Foundation

/// Status of a single script execution.
enum ScriptRunStatus: String, Codable {
    case idle
    case running
    case stopping   // SIGTERM sent, waiting for process to exit
    case succeeded
    case failed
    case cancelled
}

/// Represents one script execution against a running profile.
struct ScriptRun: Identifiable {
    let id: UUID
    let profileID: UUID
    let scriptPath: String
    private(set) var status: ScriptRunStatus
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var exitCode: Int32?
    let stdoutLogPath: String
    let stderrLogPath: String

    init(
        id: UUID = UUID(),
        profileID: UUID,
        scriptPath: String,
        stdoutLogPath: String,
        stderrLogPath: String
    ) {
        self.id = id
        self.profileID = profileID
        self.scriptPath = scriptPath
        self.status = .idle
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
    }

    mutating func markRunning() {
        status = .running
        startedAt = Date()
    }

    mutating func markSucceeded() {
        status = .succeeded
        exitCode = 0
        endedAt = Date()
    }

    mutating func markFailed(exitCode: Int32) {
        status = .failed
        self.exitCode = exitCode
        endedAt = Date()
    }

    mutating func markCancelled() {
        status = .cancelled
        endedAt = Date()
    }

    mutating func markStopping() {
        status = .stopping
    }

    /// Whether the script has finished (success, failure, or cancelled).
    /// A stopping script is NOT terminal — the process is still winding down.
    var isTerminal: Bool {
        switch status {
        case .succeeded, .failed, .cancelled:
            return true
        case .idle, .running, .stopping:
            return false
        }
    }

    /// Whether a new script can be started for this profile.
    /// Only true when the process has fully exited.
    var isReadyForNewRun: Bool {
        isTerminal
    }

    var scriptFileName: String {
        URL(fileURLWithPath: scriptPath).lastPathComponent
    }

    /// Read the last N lines of stderr for error display.
    func stderrTail(lines: Int = 20) -> String {
        guard let data = FileManager.default.contents(atPath: stderrLogPath),
              let content = String(data: data, encoding: .utf8) else {
            return ""
        }
        let allLines = content.components(separatedBy: .newlines)
        return allLines.suffix(lines).joined(separator: "\n")
    }
}
