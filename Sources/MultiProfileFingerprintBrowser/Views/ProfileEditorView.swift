import SwiftUI

struct ProfileEditorView: View {
    @Binding var draft: Profile
    var isNew: Bool
    let onSave: (Profile) -> Void
    let onCancel: () -> Void
    let onRandomize: () -> Void

    private let presets = FingerprintPresets.shared.all
    @State private var showRiskyPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew
                 ? Localization.t("New Profile", "新建配置")
                 : Localization.t("Edit Profile", "编辑配置"))
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Section(Localization.t("Identity", "基本信息")) {
                    TextField(Localization.t("Name", "名称"), text: $draft.name)
                    TextField(Localization.t("Notes", "备注"), text: $draft.notes)
                }

                Section(Localization.t("Fingerprint", "指纹")) {
                    Picker(Localization.t("Preset", "预设"), selection: Binding(
                        get: { draft.presetID ?? "" },
                        set: { newID in
                            if let preset = presets.first(where: { $0.id == newID }) {
                                draft.fingerprint = FingerprintDeriver.derive(from: preset, seed: draft.fingerprintSeed)
                                draft.presetID = preset.id
                            }
                        }
                    )) {
                        Text(Localization.t("Custom", "自定义")).tag("")
                        ForEach(filteredPresets) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                    Toggle(
                        Localization.t("Show risky Windows/Linux presets", "显示高风险 Windows/Linux 预设"),
                        isOn: $showRiskyPresets
                    )
                    .font(.system(size: 12))
                    if showRiskyPresets {
                        Label(
                            Localization.t(
                                "Risky OS presets can conflict with a macOS host GPU, fonts and media stack.",
                                "高风险 OS 预设可能与 macOS 主机 GPU、字体、媒体能力冲突。"
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    }
                    HStack {
                        Button(Localization.t("Randomize", "随机生成")) {
                            onRandomize()
                        }
                        .controlSize(.small)
                        Spacer()
                        Text("Seed: \(draft.fingerprintSeed)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(Localization.t(
                            "Stable ID: \(draft.fingerprint.stableID)",
                            "稳定标识：\(draft.fingerprint.stableID)"
                        ))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Section(Localization.t("Proxy", "代理")) {
                    Picker(Localization.t("Type", "类型"), selection: $draft.proxy.kind) {
                        Text(Localization.t("Direct", "直连")).tag(ProxyKind.none)
                        Text("HTTP").tag(ProxyKind.http)
                        Text("SOCKS5").tag(ProxyKind.socks5)
                    }
                    if draft.proxy.kind != .none {
                        TextField(Localization.t("Host", "主机"), text: $draft.proxy.host)
                        TextField(
                            Localization.t("Port", "端口"),
                            value: $draft.proxy.port,
                            format: .number.grouping(.never)
                        )
                        TextField(Localization.t("Username (optional)", "用户名（可选）"), text: $draft.proxy.username)
                        SecureField(Localization.t("Password (optional)", "密码（可选）"), text: $draft.proxy.password)
                    }
                    if let message = draft.proxy.validationMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                    }
                    if draft.proxy.kind == .none {
                        Label(
                            Localization.t(
                                "Real IP will be exposed without a proxy. Anti-detection tests will fail.",
                                "未挂代理将暴露真实 IP，反检测测试将失败。"
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                    }
                }

                Section(Localization.t("Automation", "自动化")) {
                    Toggle(
                        Localization.t("Enable Marionette (remote control)", "启用 Marionette（远程控制）"),
                        isOn: $draft.marionetteEnabled
                    )
                    Text(Localization.t(
                        "High risk: automation can expose webdriver-like artifacts. Ports are local-only.",
                        "高风险：自动化可能暴露类似 webdriver 的痕迹。端口仅绑定本机。"
                    ))
                        .font(.system(size: 11))
                        .foregroundColor(draft.marionetteEnabled ? .red : .secondary)
                }
            }

            HStack {
                Spacer()
                Button(Localization.t("Cancel", "取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(Localization.t("Save", "保存")) {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 520)
    }

    private var filteredPresets: [FingerprintPreset] {
        showRiskyPresets ? presets : FingerprintPresets.shared.macPresets
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draft.proxy.validationMessage == nil
    }
}
