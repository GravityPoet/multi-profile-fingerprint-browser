**English** | [中文](README.zh-CN.md)

# Multi-Profile Fingerprint Browser

A free, open-source Safari/WebKit-family consistent privacy fingerprint browser for macOS. Every profile gets its own cookies, storage, and stable Safari-device fingerprint, reducing cross-account and cross-site fingerprint linkage.

This is not a true anti-detect browser and cannot fill TLS / HTTP/2 / Chromium-engine fingerprint gaps. Its scope is local, zero-subscription, low-anomaly multi-profile privacy: every profile looks like a different Safari/WebKit device, never Chrome or Firefox.

## Status

- macOS 12+, Swift + WKWebView, single-file implementation (~4500 lines)
- `v0.1.0` baseline is preserved as the stable WKWebView implementation.
- Current line is `v1.1`: a Safari/WebKit privacy-enhanced release focused on stability, honesty, and low-anomaly profile consistency.
- macOS only. No Windows / Linux plans.

## Version Lines

- **v1: Safari/WebKit privacy isolation** — this repository. Low-anomaly Safari/WebKit-family profile isolation, no subscription, no Chromium/TLS claims.
- **v2: Chromium/CEF experiment** — implemented as the isolated [`chromium-v2`](chromium-v2/README.md) subproject. This is the line that owns cleaner per-profile proxy and Chromium user-data isolation.

## Core Features

### Profile Isolation
- Multiple profiles, each with its own cookies / localStorage / IndexedDB / cache (macOS 14+ via `WKWebsiteDataStore(forIdentifier:)`; macOS 12–13 falls back to the default store)
- Per-profile homepage
- Cookie JSON import / export
- One-click wipe of all data for the current profile

### Fingerprint Layer
- 5 built-in presets: MacBook Air 13, MacBook Pro 14, iMac 5K, iPad 13, iPhone 15 Pro
- One-click randomization defaults to a Mac Safari stable fingerprint; iPhone/iPad presets remain explicit choices because large Mac windows make them higher risk
- Per-profile fingerprint persisted independently
- Per-profile pinned timezone, resolved from the primary language (for example `en-US` maps to US timezones; `zh-CN` maps to `Asia/Shanghai`)
- Consistency checks for UA family, language/timezone, screen size, touch capability, and mobile viewport risk
- Overrides: UserAgent, `navigator.platform / language / languages / hardwareConcurrency / deviceMemory / maxTouchPoints`, `screen.*`, `devicePixelRatio`, `Intl.DateTimeFormat` timezone, `Date.prototype.getTimezoneOffset`, `screen.orientation`

### Anti-Detection Layer (Enhanced Privacy)
- Canvas `getImageData / toDataURL / toBlob` pixel-level stable-seed noise
- WebGL `getParameter` (UNMASKED_VENDOR / RENDERER spoofing) + `readPixels` noise
- AudioBuffer `getChannelData` + AnalyserNode `getFloatFrequencyData` float noise
- `navigator.userAgentData / plugins / mimeTypes / mediaDevices` neutralized
- `permissions.query` always returns `prompt`
- `matchMedia` hover / pointer / any-pointer tracks the touch-device fingerprint
- `Function.prototype.toString` patched — all hooked functions return `function NAME() { [native code] }`, defeating toString-based detection
- All hooks are named functions (not anonymous arrows), defeating name-based detection

### Privacy Layer
- Per-profile WebRTC protection (`RTCPeerConnection` etc set to `undefined`, `enumerateDevices` returns empty) — prevents STUN-based real IP leak when enabled
- Global Privacy Control = true

### Profile Backup / Restore
- Profile config export / import covers: name, homepage, fingerprint, pinned timezone, enhanced privacy, WebRTC protection, and proxy mapping
- Cookie export / import remains separate
- Full `WKWebsiteDataStore` cloning is intentionally not promised because it is not stable across WebKit/macOS versions

### Proxy Mapping / IP Check
- Per-profile proxy mapping can be saved as Direct, Follow System, HTTP, or SOCKS5
- The app can check the configured egress IP, country, and ASN/org with `URLSession`
- It warns when multiple saved profiles share the same proxy mapping or last detected egress IP
- WKWebView v1 does **not** guarantee clean per-profile proxy enforcement; use external tools such as `sing-box`, Clash, Surge, VPS SOCKS5, or residential proxies behind local entries like `127.0.0.1:18001`

### Browser Basics
- Multi-tab (aggregated via OS-level windows)
- History back/forward, refresh, zoom, find
- Local start page that does not connect automatically, with URL/search input
- Arbitrary https homepage
- Built-in fingerprint test page with risk overview (menu → Privacy → Fingerprint Test)

## Known Limitations / Gap vs. Commercial Products

Stated honestly. For high-adversary scenarios (Fortune 500 anti-fraud, hard Cloudflare Turnstile, enterprise-grade fingerprint.com), current state may not reliably bypass.

- **TLS / JA3 / JA4 fingerprint**: not done. macOS `URLSession` / WKWebView TLS ClientHello is controlled by the kernel — cannot be rewritten in userspace. Commercial products typically use modified Chromium.
- **HTTP/2 frame order, ALPS, HTTP/3 fingerprint**: not done. Same reason.
- **WebRTC real-IP leak**: mitigated by disabling the WebRTC API entirely. Not suitable if your workflow requires WebRTC.
- **`window.outerWidth / outerHeight`**: not rewritten. The real Mac window dimensions remain exposed, which will conflict with `screen.width=393` (iPhone preset). Intentional tradeoff to preserve a usable Mac viewport.
- **CSS `device-width / orientation` media queries**: partially covered (hover/pointer). Full viewport media queries not rewritten.
- **Web Worker / iframe isolation context**: iframe values are tested in the built-in fingerprint page. Worker values are also tested; if Worker observable values do not match the main profile, the page explicitly reports "Worker exposure is not controlled."
- **Per-profile proxy in WKWebView**: v1 stores proxy mappings and can test them with `URLSession`, but it does not claim clean WKWebView per-profile proxy isolation.
- **macOS 12 / 13**: `WKWebsiteDataStore` doesn't support per-identifier instances. Multiple profiles share the default store — degraded to "fingerprint-only isolation, no cookie isolation". macOS 14+ recommended.
- **iOS device presets (iPhone / iPad)**: UA + screen swap fine, but `safe-area-inset`, font lists, and some `window.matchMedia` viewport queries will leak. Mac presets are more reliable.

For mid-to-low-adversary scenarios (multiple ordinary SaaS accounts, reducing behavior tracking, preventing cross-site device identification, personal multi-account workflows), the current isolation level is generally sufficient. Do not treat it as a replacement for commercial anti-detect browsers in high-adversary environments.

## Comparison with Commercial Anti-Detect Browsers

| Capability | This project | Multilogin / GoLogin |
|---|---|---|
| Multi-profile isolation | yes | yes |
| Canvas / WebGL / Audio noise | yes | yes |
| UA / screen / timezone spoof | yes | yes |
| Fingerprint randomization | yes | yes |
| WebRTC disabled | yes | yes |
| `toString` detection defense | yes | yes |
| TLS / JA3 fingerprint | no | yes |
| HTTP/2 fingerprint | no | yes |
| Real Chromium engine | no (WKWebView) | yes |
| Price | $0 | from $99/month |

## Build

```bash
swift build -c release
# Package as .app
./packaging/make-app.sh
# Package as DMG
./packaging/make-dmg.sh
```

Requires Xcode Command Line Tools.

## Design Choices

- **WKWebView instead of a Chromium fork**: single-file Swift, zero dependencies, small binary. Tradeoff: cannot modify TLS fingerprint, cannot modify HTTP/2 frames. Sufficient for personal multi-account use cases.
- **Local config, no cloud**: UserDefaults + Codable. All data stays on your machine.
- **Stable-seed fingerprint**: Canvas / WebGL / Audio noise is consistent across reloads for the same profile, avoiding the "fingerprint changes every refresh" anti-tracking signal.

## Roadmap

- [x] v1.1 timezone strategy and consistency checks
- [x] v1.1 iframe / Worker diagnostic coverage
- [x] v1.1 profile config backup / restore
- [x] v1.1 proxy mapping and egress IP check panel
- [x] v2 CEF/Chromium subproject with bundled runtime, per-profile `root_cache_path` / `cache_path`, proxy mapping, IP check, and local fingerprint test page
- [ ] HTTP header `Accept-Language` / `Sec-CH-UA` sub-request coverage (not just main request)
- [x] Replace v2 launcher layer with embedded CEF
- [ ] Fingerprint template import / export (community sharing)

## License

MIT.

## Related Project

- [chatgpt-web-desktop](https://github.com/GravityPoet/chatgpt-web-desktop) — the upstream project this was split off from, focused on the ChatGPT macOS client.
