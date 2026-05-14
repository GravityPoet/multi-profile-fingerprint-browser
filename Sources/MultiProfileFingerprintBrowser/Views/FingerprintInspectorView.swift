import SwiftUI

struct FingerprintInspectorView: View {
    let fingerprint: Fingerprint

    private var sortedKeys: [String] {
        Array(fingerprint.properties.keys).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Localization.t("Fingerprint", "指纹"))
                .font(.headline)
            Text(Localization.t(
                "Stable ID: \(fingerprint.stableID)",
                "稳定标识：\(fingerprint.stableID)"
            ))
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedKeys, id: \.self) { key in
                        HStack(alignment: .top, spacing: 12) {
                            Text(key)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 220, alignment: .leading)
                                .foregroundColor(.secondary)
                            Text(Self.display(fingerprint.properties[key]))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                    }
                }
            }
            .frame(minHeight: 200)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor))
            )
        }
    }

    private static func display(_ v: FingerprintValue?) -> String {
        guard let v = v else { return "—" }
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .stringArray(let arr): return "[" + arr.joined(separator: ", ") + "]"
        case .intArray(let arr): return "[" + arr.map(String.init).joined(separator: ", ") + "]"
        case .object: return "{…}"
        }
    }
}
