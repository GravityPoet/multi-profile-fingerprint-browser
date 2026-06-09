import Foundation

/// Resolves proxy exit IP geolocation (timezone, country, locale) by
/// fetching through the proxy itself. The result is used to inject
/// concrete Camoufox config keys so timezone matches the exit IP.
enum ProxyGeoResolver {
    struct GeoInfo {
        let ip: String
        let timezone: String
        let country: String
        let latitude: Double
        let longitude: Double
    }

    /// Fetch geolocation for the proxy's exit IP through the proxy itself.
    /// The IP we get is the proxy exit IP, and the geo lookup must match
    /// that same egress path.
    static func resolve(_ proxy: ProxyConfig) async -> GeoInfo? {
        guard proxy.isEnabled else { return nil }

        // Resolve via `curl`, not URLSession: URLSession's SOCKS5 support and
        // SOCKS5/HTTP proxy authentication are unreliable on macOS, so those
        // proxies would fail here and fall back to UTC — leaving the browser
        // timezone mismatched with the exit IP (the very leak this resolver
        // exists to close). curl speaks socks5h:// (remote DNS, no resolver
        // leak) and proxy auth natively, covering every proxy kind.
        guard let data = await runCurl(curlArgs(for: proxy, url: "https://ipapi.co/json/")) else {
            AppLogger.warn("ProxyGeoResolver: curl returned no data")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.warn("ProxyGeoResolver: failed to parse JSON")
            return nil
        }
        // ipapi.co signals failure as {"error": true, "reason": "..."} (HTTP 200).
        if json["error"] as? Bool == true {
            AppLogger.warn("ProxyGeoResolver: ipapi error: \(json["reason"] as? String ?? "unknown")")
            return nil
        }

        // ipapi.co returns {"timezone": "Asia/Tokyo", "country_code": "JP",
        // "latitude": 35.68, "longitude": 139.77, ...}
        guard let tz = json["timezone"] as? String, !tz.isEmpty else {
            AppLogger.warn("ProxyGeoResolver: no timezone in response")
            return nil
        }
        let country = json["country_code"] as? String ?? ""
        let ip = json["ip"] as? String ?? ""
        let lat = json["latitude"] as? Double ?? 0
        let lon = json["longitude"] as? Double ?? 0

        AppLogger.info("ProxyGeoResolver: exit geo = \(tz) (\(country)) ip=\(ip) lat=\(lat) lon=\(lon)")
        return GeoInfo(ip: ip, timezone: tz, country: country, latitude: lat, longitude: lon)
    }

    static func exitIP(_ proxy: ProxyConfig) async -> String? {
        guard proxy.isEnabled else { return nil }
        guard let data = await runCurl(curlArgs(for: proxy, url: "https://api.ipify.org")) else {
            return nil
        }
        let ip = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ip?.isEmpty == false ? ip : nil
    }

    // MARK: - curl transport

    /// Build the `curl` argv that routes the geo lookup through the proxy.
    /// SOCKS5 uses `socks5h://` so DNS resolves at the proxy (no local leak).
    /// Credentials go in a separate `--proxy-user` argv element, never the URL,
    /// so special characters in the password can't corrupt the proxy string.
    private static func curlArgs(for proxy: ProxyConfig, url: String) -> [String] {
        let scheme: String
        switch proxy.kind {
        case .socks5: scheme = "socks5h"
        case .http:   scheme = "http"
        case .none:   scheme = "http"   // unreachable: caller guards isEnabled
        }
        var args = [
            "--silent",
            "--show-error",
            "--max-time", "15",
            "--proxy", "\(scheme)://\(proxy.host):\(proxy.port)",
        ]
        if proxy.hasCredentials {
            args += ["--proxy-user", "\(proxy.username):\(proxy.password)"]
        }
        args.append(url)
        return args
    }

    /// Run `/usr/bin/curl` off the cooperative pool. Returns stdout on a clean
    /// (exit 0) run, else nil. stderr is discarded (`--silent` keeps it tiny).
    private static func runCurl(_ args: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                proc.arguments = args
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = Pipe()
                do {
                    try proc.run()
                } catch {
                    AppLogger.warn("ProxyGeoResolver: curl spawn failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    AppLogger.warn("ProxyGeoResolver: curl exit status \(proc.terminationStatus)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Proxy config helper

    static func applyProxy(_ proxy: ProxyConfig, to config: URLSessionConfiguration) {
        switch proxy.kind {
        case .http:
            var dict: [String: Any] = [
                "HTTPEnable": true,
                "HTTPProxy": proxy.host,
                "HTTPPort": proxy.port,
                "HTTPSEnable": true,
                "HTTPSProxy": proxy.host,
                "HTTPSPort": proxy.port,
            ]
            // macOS URLSession supports basic auth via these keys for HTTP proxies.
            if proxy.hasCredentials {
                dict["HTTPProxyUsername"] = proxy.username
                dict["HTTPProxyPassword"] = proxy.password
                dict["HTTPSProxyUsername"] = proxy.username
                dict["HTTPSProxyPassword"] = proxy.password
            }
            config.connectionProxyDictionary = dict
        case .socks5:
            var dict: [String: Any] = [
                "SOCKSEnable": true,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
            // SOCKS5 auth via connectionProxyDictionary is unreliable on macOS.
            // We set it anyway as a best-effort; the URLSessionDelegate handles
            // the actual auth challenge if needed.
            if proxy.hasCredentials {
                dict["SOCKSUsername"] = proxy.username
                dict["SOCKSPassword"] = proxy.password
            }
            config.connectionProxyDictionary = dict
        case .none:
            break
        }
    }
}
