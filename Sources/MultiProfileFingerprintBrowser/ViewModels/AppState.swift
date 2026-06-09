import Combine
import Foundation

/// Single source of truth for the SwiftUI layer.
/// Wraps ProfileStore + CamoufoxRuntime + CamoufoxLauncher and republishes
/// their state as `@Published` properties so views auto-refresh.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var runningProfileIDs: Set<UUID> = []
    @Published private(set) var runningProfilesByID: [UUID: RunningProfileInfo] = [:]
    @Published private(set) var runtimeStatus: CamoufoxRuntimeStatus = .notReady
    @Published var lastErrorMessage: String?

    // MARK: Proxy safety gate
    @Published var showNoProxyAlert = false
    @Published var showProxyFailAlert = false
    @Published var showConsistencyFailAlert = false
    @Published var pendingLaunchProfileID: UUID?
    @Published var isCheckingProxy = false
    @Published var proxyCheckMessage: String?
    @Published var consistencyCheckMessage: String?
    /// Geo info resolved from proxy exit IP. Passed to launcher for timezone injection.
    private var resolvedGeo: ProxyGeoResolver.GeoInfo?

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
        let preset = FingerprintDeriver.defaultPreset()
        let seed = Profile.makeFingerprintSeed()
        let profile = Profile(
            name: finalName,
            fingerprint: FingerprintDeriver.derive(from: preset, seed: seed),
            fingerprintSeed: seed,
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
        // Refuse to delete a running profile — stop it first.
        if runningProfileIDs.contains(id) {
            lastErrorMessage = Localization.t(
                "Stop this profile before deleting it.",
                "请先停止该 Profile 再删除。"
            )
            return
        }
        runStoreOperation { try store.delete(id: id) }
    }

    func duplicateProfile(_ profile: Profile) {
        // Create a new Profile with a fresh UUID so the copy is independent.
        let seed = Profile.makeFingerprintSeed()
        let preset = profile.presetID.flatMap { FingerprintPresets.shared.preset(id: $0) }
        let copy = Profile(
            name: profile.name + Localization.t(" (copy)", "（副本）"),
            fingerprint: FingerprintDeriver.derive(from: preset, seed: seed),
            fingerprintSeed: seed,
            proxy: profile.proxy,
            notes: profile.notes,
            marionetteEnabled: profile.marionetteEnabled,
            presetID: profile.presetID
        )
        runStoreOperation { _ = try store.save(copy, allowDuplicateName: true) }
    }

    func randomizeFingerprint(for profile: Profile) {
        var updated = profile
        let seed = Profile.makeFingerprintSeed()
        let preset = FingerprintDeriver.defaultPreset()
        updated.fingerprintSeed = seed
        updated.fingerprint = FingerprintDeriver.derive(from: preset, seed: seed)
        updated.presetID = preset?.id
        runStoreOperation { try store.save(updated, allowDuplicateName: true) }
    }

    // MARK: Launch

    func launchProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        // If runtime is not ready, kick off download first.
        if case .ready = runtimeStatus {
            // Runtime is ready, proceed.
        } else {
            lastErrorMessage = Localization.t(
                "Runtime is not ready yet. Click \"Download runtime\" first.",
                "运行时尚未就绪，请先点击\"下载运行时\"。"
            )
            ensureRuntimeReadyInBackground()
            return
        }

        // Proxy safety gate: warn if no proxy configured.
        if !profile.proxy.isEnabled {
            pendingLaunchProfileID = id
            showNoProxyAlert = true
            return
        }

        // Proxy configured — validate connectivity before launch.
        validateProxyAndLaunch(profile: profile)
    }

    /// Called when user confirms launching without a proxy.
    func confirmLaunchWithoutProxy() {
        showNoProxyAlert = false
        guard let id = pendingLaunchProfileID else { return }
        pendingLaunchProfileID = nil
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        doLaunch(profile, geo: nil)
    }

    func cancelNoProxyLaunch() {
        showNoProxyAlert = false
        pendingLaunchProfileID = nil
    }

    private func validateProxyAndLaunch(profile: Profile) {
        isCheckingProxy = true
        proxyCheckMessage = nil
        resolvedGeo = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await ProxyValidator.check(profile.proxy)
            await MainActor.run {
                self.isCheckingProxy = false
                switch result {
                case .ok(let exitIP):
                    // Resolve geo from exit IP, then launch.
                    self.resolveGeoAndLaunch(profile: profile, exitIP: exitIP)
                case .warning(let msg):
                    // Non-blocking: warn but allow launch.
                    self.proxyCheckMessage = msg
                    self.doLaunch(profile, geo: nil)
                case .failed(let msg):
                    // Not a hard block — show confirmation dialog.
                    self.proxyCheckMessage = msg
                    self.pendingLaunchProfileID = profile.id
                    self.showProxyFailAlert = true
                }
            }
        }
    }

    func confirmLaunchDespiteProxyFail() {
        showProxyFailAlert = false
        guard let id = pendingLaunchProfileID else { return }
        pendingLaunchProfileID = nil
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        doLaunch(profile, geo: nil)
    }

    func confirmLaunchDespiteConsistencyFail() {
        showConsistencyFailAlert = false
        guard let id = pendingLaunchProfileID else { return }
        pendingLaunchProfileID = nil
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        doLaunch(profile, geo: resolvedGeo, skipConsistencyGate: true)
    }

    func cancelConsistencyFailLaunch() {
        showConsistencyFailAlert = false
        pendingLaunchProfileID = nil
    }

    func cancelProxyFailLaunch() {
        showProxyFailAlert = false
        pendingLaunchProfileID = nil
    }

    private func resolveGeoAndLaunch(profile: Profile, exitIP: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let geo = await ProxyGeoResolver.resolve(profile.proxy)
            await MainActor.run {
                self.resolvedGeo = geo
                if let geo {
                    AppLogger.info("Resolved proxy geo: tz=\(geo.timezone) country=\(geo.country)")
                } else {
                    AppLogger.warn("Proxy geo resolution failed; will use fallback timezone")
                }
                self.doLaunch(profile, geo: geo)
            }
        }
    }

    private func doLaunch(_ profile: Profile, geo: ProxyGeoResolver.GeoInfo?, skipConsistencyGate: Bool = false) {
        if !skipConsistencyGate {
            let report = FingerprintConsistencyScorer.score(profile: profile, geo: geo)
            if !report.canLaunch {
                consistencyCheckMessage = report.summary
                pendingLaunchProfileID = profile.id
                resolvedGeo = geo
                showConsistencyFailAlert = true
                return
            }
            if !report.warnings.isEmpty {
                proxyCheckMessage = report.summary
            }
        }
        do {
            _ = try launcher.launch(profile, geo: geo, skipConsistencyGate: skipConsistencyGate)
            refreshRunning()
        } catch {
            AppLogger.error("launch failed: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
        }
    }

    func terminateProfile(id: UUID) {
        launcher.terminate(profileID: id)
    }

    func runningInfo(for id: UUID) -> RunningProfileInfo? {
        runningProfilesByID[id]
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
        var snapshots: [UUID: RunningProfileInfo] = [:]
        for launched in launcher.running where launched.isRunning {
            snapshots[launched.profileID] = RunningProfileInfo(
                id: launched.profileID,
                processID: launched.process.processIdentifier,
                startedAt: launched.startedAt,
                marionettePort: launched.marionettePort
            )
        }
        runningProfilesByID = snapshots
        runningProfileIDs = Set(snapshots.keys)
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
