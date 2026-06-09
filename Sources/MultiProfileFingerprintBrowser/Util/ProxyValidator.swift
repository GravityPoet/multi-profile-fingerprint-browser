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

        if let ip = await ProxyGeoResolver.exitIP(proxy) {
            AppLogger.info("ProxyValidator: exit IP = \(ip)")
            return .ok(exitIP: ip)
        }
        return .failed(Localization.t(
            "Proxy probe failed: could not fetch exit IP through the configured proxy.",
            "代理探测失败：无法通过该代理获取出口 IP。"
        ))
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
