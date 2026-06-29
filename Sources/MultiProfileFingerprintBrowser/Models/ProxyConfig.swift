import Foundation

enum ProxyKind: String, Codable, CaseIterable {
    case none
    case http
    case socks5
}

struct ProxyConfig: Codable, Hashable {
    var kind: ProxyKind
    var host: String
    var port: Int
    var username: String
    var password: String

    init(
        kind: ProxyKind = .none,
        host: String = "",
        port: Int = 0,
        username: String = "",
        password: String = ""
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    static let direct = ProxyConfig()

    var isEnabled: Bool { kind != .none }

    var hasCredentials: Bool {
        !username.isEmpty || !password.isEmpty
    }

    var normalizedForStorage: ProxyConfig {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.kind == .none {
            copy.host = ""
            copy.port = 0
            copy.username = ""
            copy.password = ""
        }
        return copy
    }

    var validationMessage: String? {
        let normalized = normalizedForStorage
        guard normalized.kind != .none else { return nil }
        if normalized.host.isEmpty {
            return Localization.t(
                "Proxy host is required.",
                "代理主机不能为空。"
            )
        }
        if !(1...65535).contains(normalized.port) {
            return Localization.t(
                "Proxy port must be between 1 and 65535.",
                "代理端口必须在 1 到 65535 之间。"
            )
        }
        return nil
    }

    /// Firefox prefs for writing into the per-profile `user.js`.
    /// Authentication via username/password is handled separately at
    /// runtime (Firefox does not accept inline auth in proxy prefs).
    var firefoxPrefs: [String: AnyHashable] {
        switch kind {
        case .none:
            return ["network.proxy.type": 0]
        case .http:
            return [
                "network.proxy.type": 1,
                "network.proxy.http": host,
                "network.proxy.http_port": port,
                "network.proxy.ssl": host,
                "network.proxy.ssl_port": port,
                "network.proxy.share_proxy_settings": true,
            ]
        case .socks5:
            return [
                "network.proxy.type": 1,
                "network.proxy.socks": host,
                "network.proxy.socks_port": port,
                "network.proxy.socks_version": 5,
                "network.proxy.socks_remote_dns": true,
            ]
        }
    }

    func firefoxPrefsForLocalRelay(host: String, port: Int) -> [String: AnyHashable] {
        [
            "network.proxy.type": 1,
            "network.proxy.socks": host,
            "network.proxy.socks_port": port,
            "network.proxy.socks_version": 5,
            "network.proxy.socks_remote_dns": true,
            "network.proxy.no_proxies_on": "",
        ]
    }

    var displayString: String {
        switch kind {
        case .none:
            return Localization.t("Direct", "直连")
        case .http:
            let proxy = normalizedForStorage
            return "HTTP \(proxy.host):\(proxy.port)"
        case .socks5:
            let proxy = normalizedForStorage
            return "SOCKS5 \(proxy.host):\(proxy.port)"
        }
    }
}
