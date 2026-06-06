import Foundation

/// Validates proxy connectivity by fetching exit IP through the proxy.
enum ProxyValidator {
    enum Result {
        case ok
        case warning(String)
        case failed(String)
    }

    /// Check that the proxy is reachable and returns an exit IP different
    /// from the direct IP. Uses `api.ipify.org` (lightweight, JSON).
    static func check(_ proxy: ProxyConfig) async -> Result {
        guard proxy.isEnabled else {
            return .warning(Localization.t(
                "No proxy configured — real IP will be exposed.",
                "未配置代理 — 将暴露真实 IP。"
            ))
        }

        // Build proxied request to ipify.
        let url = URL(string: "https://api.ipify.org?format=json")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15

        switch proxy.kind {
        case .http:
            config.connectionProxyDictionary = [
                "HTTPEnable": true,
                "HTTPProxy": proxy.host,
                "HTTPPort": proxy.port,
                "HTTPSEnable": true,
                "HTTPSProxy": proxy.host,
                "HTTPSPort": proxy.port,
            ]
        case .socks5:
            config.connectionProxyDictionary = [
                "SOCKSEnable": true,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
        case .none:
            return .ok
        }

        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(Localization.t(
                    "Proxy check failed: unexpected HTTP status.",
                    "代理检测失败：HTTP 状态异常。"
                ))
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ip = json["ip"] as? String {
                AppLogger.info("Proxy exit IP: \(ip)")
                return .ok
            }
            return .warning(Localization.t(
                "Proxy responded but could not parse exit IP.",
                "代理已响应但无法解析出口 IP。"
            ))
        } catch {
            return .failed(Localization.t(
                "Proxy unreachable: \(error.localizedDescription)",
                "代理不可达：\(error.localizedDescription)"
            ))
        }
    }
}
