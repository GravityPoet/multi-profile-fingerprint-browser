import Foundation

/// Resolves proxy exit IP geolocation (timezone, country, locale) by
/// fetching through the proxy itself. The result is used to inject
/// concrete Camoufox config keys so timezone matches the exit IP.
enum ProxyGeoResolver {
    struct GeoInfo {
        let timezone: String
        let country: String
        let latitude: Double
        let longitude: Double
    }

    /// Fetch geolocation for the proxy's exit IP.
    /// Uses `ipapi.co` (free, no key, returns timezone).
    /// Must be called through the proxy — the IP we get is the exit IP,
    /// and the geo lookup must match that same IP.
    static func resolve(_ proxy: ProxyConfig) async -> GeoInfo? {
        guard proxy.isEnabled else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        applyProxy(proxy, to: config)

        // ipapi.co returns timezone, country, lat, lon for the requesting IP.
        let url = URL(string: "https://ipapi.co/json/")!
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                AppLogger.warn("ProxyGeoResolver: HTTP status != 200")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.warn("ProxyGeoResolver: failed to parse JSON")
                return nil
            }

            // ipapi.co returns {"timezone": "Asia/Tokyo", "country_code": "JP",
            // "latitude": 35.68, "longitude": 139.77, ...}
            guard let tz = json["timezone"] as? String, !tz.isEmpty else {
                AppLogger.warn("ProxyGeoResolver: no timezone in response")
                return nil
            }
            let country = json["country_code"] as? String ?? ""
            let lat = json["latitude"] as? Double ?? 0
            let lon = json["longitude"] as? Double ?? 0

            AppLogger.info("ProxyGeoResolver: exit geo = \(tz) (\(country)) lat=\(lat) lon=\(lon)")
            return GeoInfo(timezone: tz, country: country, latitude: lat, longitude: lon)
        } catch {
            AppLogger.warn("ProxyGeoResolver: request failed: \(error.localizedDescription)")
            return nil
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
