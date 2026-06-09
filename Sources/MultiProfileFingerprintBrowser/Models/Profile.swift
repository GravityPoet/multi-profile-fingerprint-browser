import Foundation

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var fingerprint: Fingerprint
    var fingerprintSeed: UInt64
    var proxy: ProxyConfig
    var notes: String
    var marionetteEnabled: Bool
    var presetID: String?

    init(
        id: UUID = UUID(),
        name: String,
        fingerprint: Fingerprint = Fingerprint(),
        fingerprintSeed: UInt64 = Profile.makeFingerprintSeed(),
        proxy: ProxyConfig = .direct,
        notes: String = "",
        marionetteEnabled: Bool = false,
        presetID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.lastUsedAt = nil
        self.fingerprint = fingerprint
        self.fingerprintSeed = fingerprintSeed
        self.proxy = proxy
        self.notes = notes
        self.marionetteEnabled = marionetteEnabled
        self.presetID = presetID
    }

    /// Folder name for this profile on disk. Includes the UUID so the
    /// directory is unique even if two profiles share a display name.
    var directoryName: String {
        id.uuidString
    }

    static func makeFingerprintSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64.max)
    }

    static func legacySeed(for id: UUID) -> UInt64 {
        let hash = SHA256Hasher.hash(data: Data(id.uuidString.utf8))
        return UInt64(hash.prefix(16), radix: 16) ?? 0x4d504642
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case lastUsedAt
        case fingerprint
        case fingerprintSeed
        case proxy
        case notes
        case marionetteEnabled
        case presetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        fingerprint = try c.decode(Fingerprint.self, forKey: .fingerprint)
        fingerprintSeed = try c.decodeIfPresent(UInt64.self, forKey: .fingerprintSeed)
            ?? Self.legacySeed(for: id)
        proxy = try c.decode(ProxyConfig.self, forKey: .proxy)
        notes = try c.decode(String.self, forKey: .notes)
        marionetteEnabled = try c.decode(Bool.self, forKey: .marionetteEnabled)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(fingerprintSeed, forKey: .fingerprintSeed)
        try c.encode(proxy, forKey: .proxy)
        try c.encode(notes, forKey: .notes)
        try c.encode(marionetteEnabled, forKey: .marionetteEnabled)
        try c.encodeIfPresent(presetID, forKey: .presetID)
    }
}
