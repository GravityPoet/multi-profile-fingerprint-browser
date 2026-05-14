import Foundation

enum ZipExtractorError: Error, LocalizedError {
    case unzipFailed(exitCode: Int32, stderr: String)
    case unzipNotFound

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let code, let stderr):
            return "unzip exited with code \(code): \(stderr)"
        case .unzipNotFound:
            return "/usr/bin/unzip not found on this system"
        }
    }
}

enum ZipExtractor {
    /// Extract `archiveURL` into `destDir`. Creates `destDir` if needed.
    /// Uses the system `/usr/bin/unzip` (always present on macOS) to
    /// preserve permissions and symlinks correctly for a `.app` bundle.
    static func unzip(_ archiveURL: URL, into destDir: URL) throws {
        let unzipURL = URL(fileURLWithPath: "/usr/bin/unzip")
        guard FileManager.default.isExecutableFile(atPath: unzipURL.path) else {
            throw ZipExtractorError.unzipNotFound
        }

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = unzipURL
        process.arguments = ["-q", "-o", archiveURL.path, "-d", destDir.path]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<no stderr>"
            throw ZipExtractorError.unzipFailed(
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }
    }
}
