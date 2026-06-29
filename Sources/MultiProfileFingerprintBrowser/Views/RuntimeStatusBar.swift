import SwiftUI

struct RuntimeStatusBar: View {
    let status: CamoufoxRuntimeStatus
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            indicator
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .top
        )
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .ready:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .downloading, .verifying, .extracting:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 8, height: 8)
        case .failed:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
        case .notReady:
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    private var label: String {
        switch status {
        case .notReady:
            return Localization.t(
                "Camoufox runtime not downloaded yet.",
                "Camoufox 运行时尚未下载。"
            )
        case .downloading(let progress):
            let pct = Int(progress * 100)
            return Localization.t(
                "Downloading runtime… \(pct)%",
                "正在下载运行时… \(pct)%"
            )
        case .verifying:
            return Localization.t(
                "Verifying SHA256…",
                "正在校验 SHA256…"
            )
        case .extracting:
            return Localization.t(
                "Extracting runtime…",
                "正在解压运行时…"
            )
        case .ready(let url):
            return Localization.t(
                "Runtime ready · \(url.path)",
                "运行时就绪 · \(url.path)"
            )
        case .failed(let msg):
            return Localization.t(
                "Runtime failed: \(msg)",
                "运行时失败：\(msg)"
            )
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .ready:
            EmptyView()
        case .downloading, .verifying, .extracting:
            EmptyView()
        case .notReady, .failed:
            Button(Localization.t("Download runtime", "下载运行时")) {
                onDownload()
            }
            .controlSize(.small)
        }
    }
}
