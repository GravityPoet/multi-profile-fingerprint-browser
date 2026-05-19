import Foundation

/// A typed leaf value of a Camoufox fingerprint config map.
/// Mirrors what the upstream Python wrapper sends via `CAMOU_CONFIG_*`.
indirect enum FingerprintValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case stringArray([String])
    case intArray([Int])
    case object([String: FingerprintValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([String].self) {
            self = .stringArray(v)
        } else if let v = try? c.decode([Int].self) {
            self = .intArray(v)
        } else if let v = try? c.decode([String: FingerprintValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.typeMismatch(
                FingerprintValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported value type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .stringArray(let v): try c.encode(v)
        case .intArray(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var asString: String? {
        if case .string(let v) = self { return v } else { return nil }
    }

    var asInt: Int? {
        if case .int(let v) = self { return v } else { return nil }
    }

    var asStringArray: [String]? {
        if case .stringArray(let v) = self { return v } else { return nil }
    }
}

/// A Camoufox fingerprint configuration. Internally a flat key→value map
/// matching Camoufox's dotted-key JSON schema, with strongly typed
/// convenience accessors for the most common fields.
struct Fingerprint: Codable, Hashable {
    var properties: [String: FingerprintValue]

    init(properties: [String: FingerprintValue] = [:]) {
        self.properties = properties
    }

    // MARK: Convenience accessors

    var userAgent: String? {
        get { properties["navigator.userAgent"]?.asString }
        set { properties["navigator.userAgent"] = newValue.map { .string($0) } }
    }

    var platform: String? {
        get { properties["navigator.platform"]?.asString }
        set { properties["navigator.platform"] = newValue.map { .string($0) } }
    }

    var languages: [String]? {
        get { properties["navigator.languages"]?.asStringArray }
        set { properties["navigator.languages"] = newValue.map { .stringArray($0) } }
    }

    var hardwareConcurrency: Int? {
        get { properties["navigator.hardwareConcurrency"]?.asInt }
        set { properties["navigator.hardwareConcurrency"] = newValue.map { .int($0) } }
    }

    var deviceMemory: Int? {
        get { properties["navigator.deviceMemory"]?.asInt }
        set { properties["navigator.deviceMemory"] = newValue.map { .int($0) } }
    }

    var screenWidth: Int? {
        get { properties["screen.width"]?.asInt }
        set { properties["screen.width"] = newValue.map { .int($0) } }
    }

    var screenHeight: Int? {
        get { properties["screen.height"]?.asInt }
        set { properties["screen.height"] = newValue.map { .int($0) } }
    }

    var timezone: String? {
        get { properties["timezone"]?.asString }
        set { properties["timezone"] = newValue.map { .string($0) } }
    }

    var webglVendor: String? {
        get { properties["webGl:vendor"]?.asString }
        set { properties["webGl:vendor"] = newValue.map { .string($0) } }
    }

    var webglRenderer: String? {
        get { properties["webGl:renderer"]?.asString }
        set { properties["webGl:renderer"] = newValue.map { .string($0) } }
    }

    // MARK: Camoufox serialization

    /// Serialize to the JSON string consumed by `CAMOU_CONFIG_*` env vars.
    /// Sorted keys give deterministic output for hashing and debugging.
    func toCamoufoxJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(properties)
        guard let str = String(data: data, encoding: .utf8) else {
            throw FingerprintError.encodingFailed
        }
        return str
    }

    /// Firefox prefs derived from fingerprint fields that need a
    /// `user.js` overlay (e.g. `intl.accept_languages` from `languages`).
    func derivedFirefoxPrefs() -> [String: AnyHashable] {
        var prefs: [String: AnyHashable] = [:]
        if let langs = languages, !langs.isEmpty {
            prefs["intl.accept_languages"] = langs.joined(separator: ",")
        }
        return prefs
    }

    /// Stable identity hash for UI display and change detection.
    /// Uses canonical JSON (sorted keys) + SHA256, truncated to 16 hex chars.
    /// Deterministic across processes and launches.
    var stableID: String {
        // Build canonical JSON manually to ensure deterministic output.
        let sorted = properties.sorted { $0.key < $1.key }
        var parts: [String] = []
        for (k, v) in sorted {
            let encoded = (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            let escapedKey = k.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("\"\(escapedKey)\":\(encoded)")
        }
        let canonical = "{\(parts.joined(separator: ","))}"
        let hash = SHA256Hasher.hash(data: Data(canonical.utf8))
        // Truncate to 16 hex chars (64 bits) for display.
        return String(hash.prefix(16))
    }
}

enum FingerprintError: Error {
    case encodingFailed
}
