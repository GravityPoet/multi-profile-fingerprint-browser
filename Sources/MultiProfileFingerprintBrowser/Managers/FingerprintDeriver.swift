import Foundation

enum FingerprintDeriver {
    static func defaultPreset() -> FingerprintPreset? {
        FingerprintPresets.shared.macPresets.randomElement()
            ?? FingerprintPresets.shared.all.randomElement()
    }

    static func randomPreset(allowRiskyOS: Bool = false) -> FingerprintPreset? {
        if allowRiskyOS {
            return FingerprintPresets.shared.all.randomElement()
        }
        return defaultPreset()
    }

    static func derive(from preset: FingerprintPreset?, seed: UInt64) -> Fingerprint {
        var fingerprint = preset?.fingerprint() ?? Fingerprint()
        applyMacSafeVariations(to: &fingerprint, seed: seed)
        return fingerprint
    }

    private static func applyMacSafeVariations(to fingerprint: inout Fingerprint, seed: UInt64) {
        let ua = fingerprint.userAgent ?? ""
        let platform = fingerprint.platform ?? ""
        let isMac = ua.contains("Macintosh") || platform == "MacIntel"
        guard isMac else { return }

        fingerprint.hardwareConcurrency = pick([8, 10, 12], seed: seed, label: "cpu")
        fingerprint.deviceMemory = pick([8, 16, 24], seed: seed, label: "memory")

        let screens = [
            (1440, 900, 1440, 805, 2.0),
            (1512, 982, 1512, 947, 2.0),
            (1728, 1117, 1728, 1085, 2.0),
            (2560, 1600, 2560, 1565, 2.0),
        ]
        let s = screens[Int(mix(seed, label: "screen") % UInt64(screens.count))]
        fingerprint.screenWidth = s.0
        fingerprint.screenHeight = s.1
        fingerprint.properties["screen.availWidth"] = .int(s.2)
        fingerprint.properties["screen.availHeight"] = .int(s.3)
        fingerprint.properties["window.devicePixelRatio"] = .double(s.4)
        fingerprint.properties["screen.colorDepth"] = .int(30)
        fingerprint.properties["screen.pixelDepth"] = .int(30)
        fingerprint.properties["navigator.maxTouchPoints"] = .int(0)
        fingerprint.properties["fonts:spacing_seed"] = .int(Int(mix(seed, label: "font-spacing") % 1_000_000) + 1)
        fingerprint.properties["AudioContext:sampleRate"] = .int(pick([44100, 48000], seed: seed, label: "audio-rate"))
        fingerprint.properties["AudioContext:outputLatency"] = .double(pick([0.01, 0.012, 0.018, 0.02], seed: seed, label: "audio-latency"))
        fingerprint.properties["AudioContext:maxChannelCount"] = .int(pick([2, 4, 6, 8], seed: seed, label: "audio-channels"))
        fingerprint.properties["webGl:vendor"] = .string("Apple Inc.")
        fingerprint.properties["webGl:renderer"] = .string(pick([
            "Apple M1",
            "Apple M2",
            "Apple M3",
            "Apple M3 Max",
        ], seed: seed, label: "webgl-renderer"))

        if let langs = fingerprint.languages, !langs.isEmpty {
            fingerprint.properties["navigator.language"] = .string(langs[0])
            let primary = langs[0]
            let pieces = primary.split(separator: "-", maxSplits: 1).map(String.init)
            fingerprint.properties["locale:language"] = .string(pieces.first ?? "en")
            if pieces.count > 1 {
                fingerprint.properties["locale:region"] = .string(pieces[1])
            }
            fingerprint.properties["locale:all"] = .string(langs.joined(separator: ", "))
        }
    }

    private static func pick<T>(_ values: [T], seed: UInt64, label: String) -> T {
        values[Int(mix(seed, label: label) % UInt64(values.count))]
    }

    static func mix(_ seed: UInt64, label: String) -> UInt64 {
        var h = seed ^ 0xcbf29ce484222325
        for b in label.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        h ^= h >> 33
        h = h &* 0xff51afd7ed558ccd
        h ^= h >> 33
        h = h &* 0xc4ceb9fe1a85ec53
        h ^= h >> 33
        return h
    }
}
