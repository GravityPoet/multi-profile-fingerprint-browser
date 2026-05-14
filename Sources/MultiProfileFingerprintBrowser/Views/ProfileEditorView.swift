import SwiftUI

struct ProfileEditorView: View {
    @Binding var draft: Profile
    var isNew: Bool
    let onSave: (Profile) -> Void
    let onCancel: () -> Void
    let onRandomize: () -> Void

    private let presets = FingerprintPresets.shared.all

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
                                draft.fingerprint = preset.fingerprint()
                                draft.presetID = preset.id
                            }
                        }
                    )) {
                        Text(Localization.t("Custom", "自定义")).tag("")
                        ForEach(presets) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                    HStack {
                        Button(Localization.t("Randomize", "随机生成")) {
                            onRandomize()
                        }
                        .controlSize(.small)
                        Spacer()
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
                }

                Section(Localization.t("Automation", "自动化")) {
                    Toggle(
                        Localization.t("Enable Marionette (remote control)", "启用 Marionette（远程控制）"),
                        isOn: $draft.marionetteEnabled
                    )
                    Text(Localization.t(
                        "Allocates a unique TCP port at launch for headless / programmatic control.",
                        "启动时为远程控制分配独立 TCP 端口。"
                    ))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 520)
    }
}
