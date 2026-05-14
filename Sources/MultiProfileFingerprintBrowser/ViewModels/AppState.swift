import Combine
import Foundation

/// Single source of truth for the SwiftUI layer.
/// Wraps ProfileStore + CamoufoxRuntime + CamoufoxLauncher and republishes
/// their state as `@Published` properties so views auto-refresh.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var runningProfileIDs: Set<UUID> = []
    @Published private(set) var runtimeStatus: CamoufoxRuntimeStatus = .notReady
    @Published var lastErrorMessage: String?

    private let store = ProfileStore.shared
    private let launcher = CamoufoxLauncher.shared
    private let runtime = CamoufoxRuntime.shared

    init() {
        reloadProfiles()
        runtime.observe { [weak self] status in
            Task { @MainActor [weak self] in
                self?.runtimeStatus = status
            }
        }
        launcher.observe { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshRunning()
            }
        }
        refreshRunning()
    }

    // MARK: Profile CRUD

    func reloadProfiles() {
        profiles = store.list()
    }

    func createProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Profile \(profiles.count + 1)"
        let finalName = trimmed.isEmpty ? fallback : trimmed
        let preset = FingerprintPresets.shared.randomPreset()
        let profile = Profile(
            name: finalName,
            fingerprint: preset?.fingerprint() ?? Fingerprint(),
            proxy: .direct,
            notes: "",
            marionetteEnabled: false,
            presetID: preset?.id
        )
        runStoreOperation { try store.save(profile) }
    }

    func updateProfile(_ profile: Profile) {
        runStoreOperation { try store.save(profile) }
    }

    func deleteProfile(id: UUID) {
        runStoreOperation { try store.delete(id: id) }
    }

    func duplicateProfile(_ profile: Profile) {
        var copy = profile
        copy.name = profile.name + Localization.t(" (copy)", "（副本）")
        runStoreOperation { _ = try store.save(copy, allowDuplicateName: true) }
    }

    func randomizeFingerprint(for profile: Profile) {
        var updated = profile
        if let preset = FingerprintPresets.shared.randomPreset() {
            updated.fingerprint = preset.fingerprint()
            updated.presetID = preset.id
        }
        runStoreOperation { try store.save(updated, allowDuplicateName: true) }
    }

    // MARK: Launch

    func launchProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        do {
            _ = try launcher.launch(profile)
            refreshRunning()
        } catch {
            AppLogger.error("launch failed: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
        }
    }

    func terminateProfile(id: UUID) {
        launcher.terminate(profileID: id)
    }

    // MARK: Runtime

    func ensureRuntimeReadyInBackground() {
        Task.detached(priority: .userInitiated) {
            do {
                _ = try CamoufoxRuntime.shared.ensureReady()
            } catch {
                await MainActor.run {
                    AppLogger.error("runtime not ready: \(error.localizedDescription)")
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Helpers

    private func refreshRunning() {
        let ids = launcher.running
            .filter { $0.isRunning }
            .map { $0.profileID }
        runningProfileIDs = Set(ids)
    }

    private func runStoreOperation(_ op: () throws -> Void) {
        do {
            try op()
            reloadProfiles()
        } catch {
            AppLogger.error("store op failed: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
        }
    }
}
