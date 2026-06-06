import Foundation

/// Validates proxy connectivity by fetching exit IP through the proxy.
/// Returns the exit IP on success so callers can use it for geo lookup.
enum ProxyValidator {
    enum Result {
        case ok(exitIP: String)
        case warning(String)
        case failed(String)
    }

    /// Check that the proxy is reachable and returns an exit IP.
    /// Uses `api.ipify.org` (lightweight, JSON).
    static func check(_ proxy: ProxyConfig) async -> Result {
        guard proxy.isEnabled else {
            return .warning(Localization.t(
                "No proxy configured — real IP will be exposed.",
                "未配置代理 — 将暴露真实 IP。"
            ))
        }

        // SOCKS5 with credentials: URLSession SOCKS5 auth is unreliable on macOS.
        // Skip the probe and return a warning — the browser (Camoufox) handles
        // SOCKS5 auth via user.js natively, so we trust the user's config.
        if proxy.kind == .socks5 && proxy.hasCredentials {
            AppLogger.info("ProxyValidator: SOCKS5+auth, skipping probe (browser handles natively)")
            return .warning(Localization.t(
                "SOCKS5 with auth — skipping connectivity probe. Browser will handle authentication.",
                "SOCKS5 认证代理 — 跳过连通性探测，浏览器将自行处理认证。"
            ))
        }

        let url = URL(string: "https://api.ipify.org?format=json")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        ProxyGeoResolver.applyProxy(proxy, to: config)

        let delegate = ProxyAuthDelegate(proxy: proxy)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

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
                AppLogger.info("ProxyValidator: exit IP = \(ip)")
                return .ok(exitIP: ip)
            }
            return .warning(Localization.t(
                "Proxy responded but could not parse exit IP.",
                "代理已响应但无法解析出口 IP。"
            ))
        } catch {
            return .failed(Localization.t(
                "Proxy probe failed: \(error.localizedDescription)",
                "代理探测失败：\(error.localizedDescription)"
            ))
        }
    }
}

/// URLSession delegate that handles HTTP proxy authentication challenges.
/// For SOCKS5, auth is handled via connectionProxyDictionary keys (best-effort)
/// or skipped entirely (see ProxyValidator.check).
private final class ProxyAuthDelegate: NSObject, URLSessionDelegate {
    let proxy: ProxyConfig

    init(proxy: ProxyConfig) {
        self.proxy = proxy
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Handle HTTP proxy authentication (407).
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodHTTPProxy",
           proxy.hasCredentials {
            let credential = URLCredential(
                user: proxy.username,
                password: proxy.password,
                persistence: .forSession
            )
            AppLogger.info("ProxyAuthDelegate: providing proxy credentials")
            completionHandler(.useCredential, credential)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
