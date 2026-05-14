import Foundation

struct FingerprintPreset: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let os: String
    let browser: String
    let properties: [String: FingerprintValue]

    func fingerprint() -> Fingerprint {
        Fingerprint(properties: properties)
    }
}

enum FingerprintPresetsError: Error, LocalizedError {
    case resourceMissing
    case decodeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            return "Bundled fingerprint preset JSON is missing"
        case .decodeFailed(let err):
            return "Failed to decode fingerprint presets: \(err.localizedDescription)"
        }
    }
}

/// Loads the embedded `fingerprint-presets-v150.json` once and serves
/// random or by-id lookups. The JSON itself is hand-curated to cover
/// the major OS × browser combinations expected by anti-detect testers.
final class FingerprintPresets {
    static let shared = FingerprintPresets()

    private let presets: [FingerprintPreset]

    private init() {
        do {
            self.presets = try Self.loadFromBundle()
            AppLogger.info("Loaded \(presets.count) fingerprint presets")
        } catch {
            AppLogger.error("FingerprintPresets load failed: \(error.localizedDescription)")
            self.presets = []
        }
    }

    private static func loadFromBundle() throws -> [FingerprintPreset] {
        guard let url = Bundle.module.url(
            forResource: "fingerprint-presets-v150",
            withExtension: "json"
        ) else {
            throw FingerprintPresetsError.resourceMissing
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode([FingerprintPreset].self, from: data)
        } catch {
            throw FingerprintPresetsError.decodeFailed(error)
        }
    }

    // MARK: Lookup

    var all: [FingerprintPreset] { presets }

    func preset(id: String) -> FingerprintPreset? {
        presets.first { $0.id == id }
    }

    /// Uniform random selection. Returns `nil` only if the bundle failed to load.
    func randomPreset() -> FingerprintPreset? {
        presets.randomElement()
    }

    /// Build a ready-to-use `Fingerprint` from a random preset.
    /// Falls back to an empty fingerprint if no presets are available.
    func randomFingerprint() -> Fingerprint {
        randomPreset()?.fingerprint() ?? Fingerprint()
    }
}
