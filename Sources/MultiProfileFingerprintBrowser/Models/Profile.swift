import Foundation

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var fingerprint: Fingerprint
    var proxy: ProxyConfig
    var notes: String
    var marionetteEnabled: Bool
    var presetID: String?

    init(
        id: UUID = UUID(),
        name: String,
        fingerprint: Fingerprint = Fingerprint(),
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
}
