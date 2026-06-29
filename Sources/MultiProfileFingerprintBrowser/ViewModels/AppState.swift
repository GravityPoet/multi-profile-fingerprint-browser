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
    private var runtimeTask: Task<Void, Never>?

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
        _ = saveProfile(profile)
    }

    @discardableResult
    func updateProfile(_ profile: Profile) -> Bool {
        saveProfile(profile)
    }

    @discardableResult
    func deleteProfile(id: UUID) -> Bool {
        // Refuse to delete a running profile — stop it first.
        if runningProfileIDs.contains(id) {
            lastErrorMessage = Localization.t(
                "Stop this profile before deleting it.",
                "请先停止该 Profile 再删除。"
            )
            return false
        }
        return runStoreOperation { try store.delete(id: id) }
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
        _ = saveProfile(copy, allowDuplicateName: true)
    }

    func randomizeFingerprint(for profile: Profile) {
        var updated = profile
        let seed = Profile.makeFingerprintSeed()
        let preset = FingerprintDeriver.defaultPreset()
        updated.fingerprintSeed = seed
        updated.fingerprint = FingerprintDeriver.derive(from: preset, seed: seed)
        updated.presetID = preset?.id
        _ = saveProfile(updated, allowDuplicateName: true)
    }

    // MARK: Launch

    func launchProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        clearLaunchPrompts()

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

        if let message = profile.proxy.validationMessage {
            lastErrorMessage = message
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
        proxyCheckMessage = nil
        consistencyCheckMessage = nil
        resolvedGeo = nil
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
                    self.isCheckingProxy = true
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
        consistencyCheckMessage = nil
        resolvedGeo = nil
    }

    func cancelProxyFailLaunch() {
        showProxyFailAlert = false
        pendingLaunchProfileID = nil
        proxyCheckMessage = nil
        resolvedGeo = nil
    }

    private func resolveGeoAndLaunch(profile: Profile, exitIP: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let geo = await ProxyGeoResolver.resolve(profile.proxy)
            await MainActor.run {
                self.isCheckingProxy = false
                self.resolvedGeo = geo
                if let geo {
                    let mismatch = !geo.ip.isEmpty && geo.ip != exitIP
                    AppLogger.info("Resolved proxy geo: tz=\(geo.timezone) country=\(geo.country) ip=\(geo.ip)")
                    if mismatch {
                        self.proxyCheckMessage = Localization.t(
                            "Proxy exit IP changed between checks: \(exitIP) -> \(geo.ip).",
                            "代理出口 IP 在检测期间发生变化：\(exitIP) -> \(geo.ip)。"
                        )
                    }
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
            pendingLaunchProfileID = nil
            resolvedGeo = nil
            consistencyCheckMessage = nil
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
        guard runtimeTask == nil else { return }
        runtimeTask = Task.detached(priority: .userInitiated) { [weak self] in
            var runtimeError: Error?
            do {
                _ = try CamoufoxRuntime.shared.ensureReady()
            } catch {
                runtimeError = error
            }
            await self?.finishRuntimeEnsure(error: runtimeError)
        }
    }

    private func finishRuntimeEnsure(error: Error?) {
        if let error {
            AppLogger.error("runtime not ready: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
        }
        runtimeTask = nil
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

    private func normalizedForStorage(_ profile: Profile) -> Profile {
        var copy = profile
        copy.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.proxy = profile.proxy.normalizedForStorage
        return copy
    }

    @discardableResult
    private func saveProfile(_ profile: Profile, allowDuplicateName: Bool = false) -> Bool {
        let normalized = normalizedForStorage(profile)
        if let message = normalized.proxy.validationMessage {
            lastErrorMessage = message
            return false
        }
        return runStoreOperation {
            try store.save(normalized, allowDuplicateName: allowDuplicateName)
        }
    }

    private func clearLaunchPrompts() {
        showNoProxyAlert = false
        showProxyFailAlert = false
        showConsistencyFailAlert = false
        pendingLaunchProfileID = nil
        proxyCheckMessage = nil
        consistencyCheckMessage = nil
        resolvedGeo = nil
    }

    @discardableResult
    private func runStoreOperation(_ op: () throws -> Void) -> Bool {
        do {
            try op()
            reloadProfiles()
            return true
        } catch {
            AppLogger.error("store op failed: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
            return false
        }
    }
}
