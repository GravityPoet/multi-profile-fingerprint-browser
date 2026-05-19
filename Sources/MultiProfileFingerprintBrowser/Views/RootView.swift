import AppKit
import SwiftUI

struct RootView: View {
    @StateObject var state = AppState()
    @StateObject var scriptRunner = ScriptRunner.shared
    @State private var selection: UUID?
    @State private var editingProfile: Profile?
    @State private var isNewProfile = false
    @State private var selectedScriptPath: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                profileList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                detailPane
                    .frame(minWidth: 480)
            }
            RuntimeStatusBar(
                status: state.runtimeStatus,
                onDownload: { state.ensureRuntimeReadyInBackground() }
            )
        }
        .frame(minWidth: 920, minHeight: 600)
        .sheet(item: $editingProfile) { _ in
            ProfileEditorView(
                draft: Binding(
                    get: { editingProfile ?? selectedProfile() ?? defaultDraft() },
                    set: { editingProfile = $0 }
                ),
                isNew: isNewProfile,
                onSave: { saved in
                    state.updateProfile(saved)
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil },
                onRandomize: {
                    if var draft = editingProfile,
                       let preset = FingerprintPresets.shared.randomPreset() {
                        draft.fingerprint = preset.fingerprint()
                        draft.presetID = preset.id
                        editingProfile = draft
                    }
                }
            )
        }
        .alert(
            Localization.t("Error", "错误"),
            isPresented: Binding(
                get: { state.lastErrorMessage != nil },
                set: { if !$0 { state.lastErrorMessage = nil } }
            ),
            presenting: state.lastErrorMessage
        ) { _ in
            Button(Localization.t("OK", "确定"), role: .cancel) { state.lastErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                beginNew()
            } label: {
                Label(Localization.t("New", "新建"), systemImage: "plus")
            }

            Button {
                if let profile = selectedProfile() { beginEdit(profile) }
            } label: {
                Label(Localization.t("Edit", "编辑"), systemImage: "pencil")
            }
            .disabled(selection == nil)

            Button {
                if let profile = selectedProfile() { state.duplicateProfile(profile) }
            } label: {
                Label(Localization.t("Duplicate", "复制"), systemImage: "doc.on.doc")
            }
            .disabled(selection == nil)

            Button {
                if let id = selection { state.deleteProfile(id: id); selection = nil }
            } label: {
                Label(Localization.t("Delete", "删除"), systemImage: "trash")
            }
            .disabled(selection == nil)

            Spacer()

            Button {
                if let id = selection { state.launchProfile(id: id) }
            } label: {
                Label(Localization.t("Launch", "启动"), systemImage: "play.fill")
            }
            .disabled(selection == nil || isSelectedRunning())

            Button {
                if let id = selection { state.terminateProfile(id: id) }
            } label: {
                Label(Localization.t("Stop", "停止"), systemImage: "stop.fill")
            }
            .disabled(!isSelectedRunning())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: List

    private var profileList: some View {
        Group {
            if state.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(Localization.t("No profiles yet.", "暂无配置。"))
                        .foregroundColor(.secondary)
                    Button(Localization.t("Create your first profile", "创建第一个配置")) {
                        beginNew()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                List(selection: $selection) {
                    ForEach(state.profiles) { profile in
                        ProfileListRow(
                            profile: profile,
                            isRunning: state.runningProfileIDs.contains(profile.id)
                        )
                        .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let profile = selectedProfile() {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(for: profile)
                    Divider()
                    metaSection(for: profile)
                    Divider()
                    automationSection(for: profile)
                    Divider()
                    scriptRunnerSection(for: profile)
                    Divider()
                    FingerprintInspectorView(fingerprint: profile.fingerprint)
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text(Localization.t("Select a profile to inspect.", "选择一个配置查看详情。"))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headerSection(for profile: Profile) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                if !profile.notes.isEmpty {
                    Text(profile.notes)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if state.runningProfileIDs.contains(profile.id) {
                Label(
                    Localization.t("Running", "运行中"),
                    systemImage: "circle.fill"
                )
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(.green)
                    .font(.system(size: 12))
            }
        }
    }

    private func metaSection(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metaRow(Localization.t("Proxy", "代理"), profile.proxy.displayString)
            metaRow(
                Localization.t("Preset", "预设"),
                profile.presetID.flatMap { FingerprintPresets.shared.preset(id: $0)?.label } ?? Localization.t("Custom", "自定义")
            )
            metaRow(
                Localization.t("Marionette", "Marionette"),
                profile.marionetteEnabled
                    ? Localization.t("Enabled", "已启用")
                    : Localization.t("Disabled", "已禁用")
            )
            metaRow(
                Localization.t("Created", "创建时间"),
                profile.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
            if let lastUsed = profile.lastUsedAt {
                metaRow(
                    Localization.t("Last used", "最近使用"),
                    lastUsed.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
    }

    private func automationSection(for profile: Profile) -> some View {
        let runningInfo = state.runningInfo(for: profile.id)
        let endpoint = runningInfo?.marionetteEndpoint

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Localization.t("Automation", "自动化"))
                    .font(.headline)
                Spacer()
                if let endpoint = endpoint {
                    Label(endpoint, systemImage: "terminal")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Text(automationStatusText(profile: profile, runningInfo: runningInfo))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    if let endpoint = endpoint {
                        copyToClipboard(endpoint)
                    }
                } label: {
                    Label(Localization.t("Copy endpoint", "复制端点"), systemImage: "link")
                }
                .disabled(endpoint == nil)

                Button {
                    if let text = automationEnvironmentText(for: profile, runningInfo: runningInfo) {
                        copyToClipboard(text)
                    }
                } label: {
                    Label(Localization.t("Copy script env", "复制脚本环境"), systemImage: "doc.on.clipboard")
                }
                .disabled(runningInfo == nil)
            }
            .controlSize(.small)
        }
    }

    private func scriptRunnerSection(for profile: Profile) -> some View {
        let runningInfo = state.runningInfo(for: profile.id)
        let isProfileRunning = runningInfo != nil
        let isScriptRunning = scriptRunner.isRunning(profileID: profile.id)
        let lastRun = scriptRunner.currentOrLastRun(for: profile.id)

        return VStack(alignment: .leading, spacing: 10) {
            Text(Localization.t("Script Runner", "脚本执行器"))
                .font(.headline)

            if !isProfileRunning {
                Text(Localization.t(
                    "Launch this profile first, then select a script to run.",
                    "先启动该 Profile，然后选择要执行的脚本。"
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button {
                        selectScriptFile()
                    } label: {
                        Label(
                            selectedScriptPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                                ?? Localization.t("Select script…", "选择脚本…"),
                            systemImage: "doc.badge.plus"
                        )
                    }
                    .frame(maxWidth: 240)

                    Button {
                        runScript(profile: profile, runningInfo: runningInfo!)
                    } label: {
                        Label(Localization.t("Run", "执行"), systemImage: "play.circle")
                    }
                    .disabled(selectedScriptPath == nil || isScriptRunning)

                    Button {
                        scriptRunner.stop(profileID: profile.id)
                    } label: {
                        Label(Localization.t("Stop", "停止"), systemImage: "stop.circle")
                    }
                    .disabled(!isScriptRunning)

                    Button {
                        revealLastLogs()
                    } label: {
                        Label(Localization.t("Reveal logs", "打开日志"), systemImage: "folder")
                    }
                    .disabled(lastRun == nil)

                    Button {
                        openExamplesFolder()
                    } label: {
                        Label(Localization.t("Examples", "示例"), systemImage: "book")
                    }
                }
                .controlSize(.small)

                if let run = lastRun {
                    HStack(spacing: 12) {
                        Label(
                            scriptStatusLabel(run.status),
                            systemImage: scriptStatusIcon(run.status)
                        )
                        .foregroundColor(scriptStatusColor(run.status))
                        .font(.system(size: 12))

                        if let exitCode = run.exitCode {
                            Text("exit \(exitCode)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Text(run.scriptFileName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if run.status == .failed {
                        let tail = run.stderrTail(lines: 8)
                        if !tail.isEmpty {
                            Text(tail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red)
                                .lineLimit(6)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        }
    }

    private func scriptStatusLabel(_ status: ScriptRunStatus) -> String {
        switch status {
        case .idle: return Localization.t("Idle", "空闲")
        case .running: return Localization.t("Running", "运行中")
        case .stopping: return Localization.t("Stopping", "停止中")
        case .succeeded: return Localization.t("Succeeded", "成功")
        case .failed: return Localization.t("Failed", "失败")
        case .cancelled: return Localization.t("Cancelled", "已取消")
        }
    }

    private func scriptStatusIcon(_ status: ScriptRunStatus) -> String {
        switch status {
        case .idle: return "circle"
        case .running: return "circle.fill"
        case .stopping: return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private func scriptStatusColor(_ status: ScriptRunStatus) -> Color {
        switch status {
        case .idle: return .secondary
        case .running: return .orange
        case .stopping: return .yellow
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private func selectScriptFile() {
        let panel = NSOpenPanel()
        panel.title = Localization.t("Select Script", "选择脚本")
        panel.allowedContentTypes = [.unixExecutable, .shellScript, .pythonScript, .perlScript, .rubyScript]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedScriptPath = url.path
        }
    }

    private func runScript(profile: Profile, runningInfo: RunningProfileInfo) {
        guard let scriptPath = selectedScriptPath else { return }
        do {
            _ = try scriptRunner.start(
                scriptPath: scriptPath,
                profile: profile,
                runningInfo: runningInfo
            )
        } catch {
            state.lastErrorMessage = error.localizedDescription
        }
    }

    private func revealLastLogs() {
        guard let profileID = selection,
              let run = scriptRunner.currentOrLastRun(for: profileID) else { return }
        let logDir = URL(fileURLWithPath: run.stdoutLogPath).deletingLastPathComponent()
        NSWorkspace.shared.open(logDir)
    }

    private func openExamplesFolder() {
        // Priority: Bundle Resources/examples/automation (installed app),
        // then repo-relative paths (development).
        let candidates: [URL] = [
            Bundle.main.resourceURL.map { $0.appendingPathComponent("examples/automation") },
            Bundle.main.resourceURL.map { $0.appendingPathComponent("examples") },
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("examples/automation"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("examples/automation"),
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    // MARK: Helpers

    private func selectedProfile() -> Profile? {
        guard let id = selection else { return nil }
        return state.profiles.first { $0.id == id }
    }

    private func isSelectedRunning() -> Bool {
        guard let id = selection else { return false }
        return state.runningProfileIDs.contains(id)
    }

    private func beginNew() {
        let preset = FingerprintPresets.shared.randomPreset()
        let draft = Profile(
            name: defaultName(),
            fingerprint: preset?.fingerprint() ?? Fingerprint(),
            proxy: .direct,
            notes: "",
            marionetteEnabled: false,
            presetID: preset?.id
        )
        isNewProfile = true
        editingProfile = draft
    }

    private func beginEdit(_ profile: Profile) {
        isNewProfile = false
        editingProfile = profile
    }

    private func defaultDraft() -> Profile {
        Profile(name: "")
    }

    private func defaultName() -> String {
        let n = state.profiles.count + 1
        return Localization.t("Profile \(n)", "配置 \(n)")
    }

    private func automationStatusText(
        profile: Profile,
        runningInfo: RunningProfileInfo?
    ) -> String {
        if !profile.marionetteEnabled {
            return Localization.t(
                "Enable Marionette in the profile editor, then launch this profile to expose a local automation endpoint.",
                "在配置编辑器里启用 Marionette，然后启动该 Profile，即可暴露本地自动化端点。"
            )
        }
        guard let runningInfo = runningInfo else {
            return Localization.t(
                "Marionette is enabled. Launch this profile to allocate an endpoint for Selenium/geckodriver or Marionette clients.",
                "Marionette 已启用。启动该 Profile 后，会为 Selenium/geckodriver 或 Marionette 客户端分配端点。"
            )
        }
        if runningInfo.marionetteEndpoint != nil {
            return Localization.t(
                "This running profile can be controlled by local automation. Keep the window visible so failed scripts can be inspected and continued manually.",
                "该运行中的 Profile 可被本地自动化控制。保持窗口可见，脚本失败后可人工检查并继续。"
            )
        }
        return Localization.t(
            "This profile is running, but no automation port was allocated. Stop it, enable Marionette, and launch again.",
            "该 Profile 正在运行，但未分配自动化端口。停止后启用 Marionette，再重新启动。"
        )
    }

    private func automationEnvironmentText(
        for profile: Profile,
        runningInfo: RunningProfileInfo?
    ) -> String? {
        guard let runningInfo = runningInfo else { return nil }
        return runningInfo
            .automationEnvironment(for: profile)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellEscaped($0.value))" }
            .joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct ProfileListRow: View {
    let profile: Profile
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(profile.proxy.displayString)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if let presetID = profile.presetID,
                       let preset = FingerprintPresets.shared.preset(id: presetID) {
                        Text("·").foregroundColor(.secondary)
                        Text(preset.os)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
