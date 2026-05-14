import Foundation
import OSLog

enum LogLevel: String {
    case debug
    case info
    case warn
    case error
}

enum AppLogger {
    private static let subsystem = "local.multi-profile-fingerprint-browser"
    private static let osLogger = os.Logger(subsystem: subsystem, category: "app")

    static func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.debug, message: message(), file: file, line: line)
    }

    static func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.info, message: message(), file: file, line: line)
    }

    static func warn(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.warn, message: message(), file: file, line: line)
    }

    static func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.error, message: message(), file: file, line: line)
    }

    private static func emit(_ level: LogLevel, message: String, file: String, line: Int) {
        let location = "\(file):\(line)"
        let line = "[\(level.rawValue.uppercased())] \(location) \(message)"
        switch level {
        case .debug:
            osLogger.debug("\(line, privacy: .public)")
        case .info:
            osLogger.info("\(line, privacy: .public)")
        case .warn:
            osLogger.warning("\(line, privacy: .public)")
        case .error:
            osLogger.error("\(line, privacy: .public)")
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
