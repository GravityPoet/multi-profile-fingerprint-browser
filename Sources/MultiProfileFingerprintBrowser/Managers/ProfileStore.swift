import Foundation

enum ProfileStoreError: Error, LocalizedError {
    case profileNotFound(UUID)
    case duplicateName(String)
    case ioFailure(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "Profile \(id.uuidString) not found"
        case .duplicateName(let name):
            return "Profile name '\(name)' is already in use"
        case .ioFailure(let url, let err):
            return "I/O failure at \(url.path): \(err.localizedDescription)"
        }
    }
}

/// Disk-backed CRUD store for `Profile` records.
/// One directory per profile under `AppPaths.profilesDir`.
final class ProfileStore {
    static let shared = ProfileStore()

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // MARK: List / Get

    func list() -> [Profile] {
        do {
            try AppPaths.ensureExists()
            let contents = try fm.contentsOfDirectory(
                at: AppPaths.profilesDir,
                includingPropertiesForKeys: nil
            )
            var profiles: [Profile] = []
            for dir in contents where dir.hasDirectoryPath {
                let metaURL = dir.appendingPathComponent("meta.json")
                guard fm.fileExists(atPath: metaURL.path) else { continue }
                do {
                    let data = try Data(contentsOf: metaURL)
                    let profile = try decoder.decode(Profile.self, from: data)
                    profiles.append(profile)
                } catch {
                    AppLogger.warn("Skipping unreadable profile at \(metaURL.path): \(error.localizedDescription)")
                }
            }
            profiles.sort { $0.createdAt < $1.createdAt }
            return profiles
        } catch {
            AppLogger.error("Failed to list profiles: \(error.localizedDescription)")
            return []
        }
    }

    func get(id: UUID) -> Profile? {
        list().first { $0.id == id }
    }

    // MARK: Save / Delete

    /// Create or update. Returns the saved profile.
    @discardableResult
    func save(_ profile: Profile, allowDuplicateName: Bool = false) throws -> Profile {
        try AppPaths.ensureExists()

        if !allowDuplicateName {
            let conflict = list().first { $0.id != profile.id && $0.name == profile.name }
            if conflict != nil {
                throw ProfileStoreError.duplicateName(profile.name)
            }
        }

        let dir = AppPaths.profileDir(for: profile)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let metaURL = AppPaths.profileMetaURL(for: profile)
        do {
            let data = try encoder.encode(profile)
            try data.write(to: metaURL, options: .atomic)
            // Restrict permissions — meta.json may contain proxy credentials.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
        } catch {
            throw ProfileStoreError.ioFailure(metaURL, underlying: error)
        }

        AppLogger.info("Saved profile \(profile.id) name=\(profile.name)")
        return profile
    }

    func delete(id: UUID) throws {
        guard let profile = get(id: id) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        let dir = AppPaths.profileDir(for: profile)
        do {
            try fm.removeItem(at: dir)
        } catch {
            throw ProfileStoreError.ioFailure(dir, underlying: error)
        }
        AppLogger.info("Deleted profile \(id) name=\(profile.name)")
    }

    /// Touch `lastUsedAt` on launch so the UI can sort by recency.
    func recordLaunch(of profile: Profile) throws {
        var updated = profile
        updated.lastUsedAt = Date()
        try save(updated, allowDuplicateName: true)
    }
}
