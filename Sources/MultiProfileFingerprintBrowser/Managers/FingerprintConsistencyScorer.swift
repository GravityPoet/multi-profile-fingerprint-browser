import Foundation

enum ConsistencyLevel: String, Codable {
    case warning
    case critical
}

struct ConsistencyFinding: Codable, Hashable {
    let level: ConsistencyLevel
    let message: String
}

struct ConsistencyReport: Codable, Hashable {
    let findings: [ConsistencyFinding]

    var criticals: [ConsistencyFinding] {
        findings.filter { $0.level == .critical }
    }

    var warnings: [ConsistencyFinding] {
        findings.filter { $0.level == .warning }
    }

    var canLaunch: Bool {
        criticals.isEmpty
    }

    var summary: String {
        findings.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
    }
}

enum FingerprintConsistencyScorer {
    static func score(profile: Profile, geo: ProxyGeoResolver.GeoInfo?) -> ConsistencyReport {
        var findings: [ConsistencyFinding] = []
        let fp = profile.fingerprint
        let ua = fp.userAgent ?? ""
        let platform = fp.platform ?? ""
        let oscpu = fp.properties["navigator.oscpu"]?.asString ?? ""
        let isMacUA = ua.contains("Macintosh") || ua.contains("Mac OS X")

        if isMacUA {
            if platform != "MacIntel" {
                findings.append(.init(level: .critical, message: "macOS UA requires navigator.platform=MacIntel, got \(platform.isEmpty ? "empty" : platform)."))
            }
            if !oscpu.isEmpty && !oscpu.contains("Mac OS X") && !oscpu.contains("Intel Mac OS X") {
                findings.append(.init(level: .critical, message: "macOS UA conflicts with navigator.oscpu=\(oscpu)."))
            }
            let dpr = fp.properties["window.devicePixelRatio"]
            if case .double(let value) = dpr, value < 1.0 || value > 3.0 {
                findings.append(.init(level: .warning, message: "Mac devicePixelRatio is unusual: \(value)."))
            }
            if let width = fp.screenWidth, let height = fp.screenHeight,
               width < 1200 || height < 700 || width > 4096 || height > 2600 {
                findings.append(.init(level: .warning, message: "Mac screen size is outside the normal laptop/desktop range: \(width)x\(height)."))
            }
            if let cpu = fp.hardwareConcurrency, ![4, 6, 8, 10, 12, 16].contains(cpu) {
                findings.append(.init(level: .warning, message: "Mac hardwareConcurrency is unusual: \(cpu)."))
            }
            if let memory = fp.deviceMemory, ![4, 8, 16, 24, 32].contains(memory) {
                findings.append(.init(level: .warning, message: "Mac deviceMemory is unusual: \(memory)."))
            }
        }

        if let langs = fp.languages, !langs.isEmpty {
            let navLanguage = fp.properties["navigator.language"]?.asString
            if let navLanguage, navLanguage != langs[0] {
                findings.append(.init(level: .critical, message: "navigator.language=\(navLanguage) conflicts with navigator.languages[0]=\(langs[0])."))
            }
        }

        if let geo, let tz = fp.timezone, !tz.isEmpty, tz != geo.timezone {
            findings.append(.init(level: .critical, message: "Fingerprint timezone \(tz) conflicts with proxy timezone \(geo.timezone)."))
        }

        if profile.proxy.isEnabled, geo == nil {
            findings.append(.init(level: .warning, message: "Proxy is enabled but geo/timezone could not be verified before launch."))
        }

        if profile.marionetteEnabled {
            findings.append(.init(level: .warning, message: "Marionette automation is enabled and may expose automation artifacts."))
        }

        return ConsistencyReport(findings: findings)
    }
}
