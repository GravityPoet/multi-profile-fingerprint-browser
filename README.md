**English** | [中文](README.zh-CN.md)

# Multi-Profile Fingerprint Browser

A free, open-source fingerprint-isolated browser for macOS. Every profile gets its own cookies, storage, and browser fingerprint — remote sites see a different device and a different user per profile.

Built to break the paid anti-detect browser monopoly (Multilogin, GoLogin, AdsPower) by offering the same core capabilities as a local, zero-subscription alternative.

## Status

- macOS 12+, Swift + WKWebView, single-file implementation (~3000 lines)
- Usable, but in early 0.1.0. Anti-detection details still iterating.
- macOS only. No Windows / Linux plans.

## Core Features

### Profile Isolation
- Multiple profiles, each with its own cookies / localStorage / IndexedDB / cache (macOS 14+ via `WKWebsiteDataStore(forIdentifier:)`; macOS 12–13 falls back to the default store)
- Per-profile homepage
- Cookie JSON import / export
- One-click wipe of all data for the current profile

### Fingerprint Layer
- 5 built-in presets: MacBook Air 13, MacBook Pro 14, iMac 5K, iPad 13, iPhone 15 Pro
- One-click randomization (weighted 70% Mac / 20% iPad / 10% iPhone)
- Per-profile fingerprint persisted independently
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
- WebRTC fully disabled (`RTCPeerConnection` etc set to `undefined`, `enumerateDevices` returns empty) — prevents STUN-based real IP leak
- Global Privacy Control = true

### Browser Basics
- Multi-tab (aggregated via OS-level windows)
- History back/forward, refresh, zoom, find
- Arbitrary https homepage
- Built-in fingerprint test page (menu → Privacy → Fingerprint Test)

## Known Limitations / Gap vs. Commercial Products

Stated honestly. For high-adversary scenarios (Fortune 500 anti-fraud, hard Cloudflare Turnstile, enterprise-grade fingerprint.com), current state may not reliably bypass.

- **TLS / JA3 / JA4 fingerprint**: not done. macOS `URLSession` / WKWebView TLS ClientHello is controlled by the kernel — cannot be rewritten in userspace. Commercial products typically use modified Chromium.
- **HTTP/2 frame order, ALPS, HTTP/3 fingerprint**: not done. Same reason.
- **WebRTC real-IP leak**: mitigated by disabling the WebRTC API entirely. Not suitable if your workflow requires WebRTC.
- **`window.outerWidth / outerHeight`**: not rewritten. The real Mac window dimensions remain exposed, which will conflict with `screen.width=393` (iPhone preset). Intentional tradeoff to preserve a usable Mac viewport.
- **CSS `device-width / orientation` media queries**: partially covered (hover/pointer). Full viewport media queries not rewritten.
- **Web Worker / iframe isolation context**: injection uses `forMainFrameOnly: false` so iframes are covered. Worker context coverage not yet verified.
- **macOS 12 / 13**: `WKWebsiteDataStore` doesn't support per-identifier instances. Multiple profiles share the default store — degraded to "fingerprint-only isolation, no cookie isolation". macOS 14+ recommended.
- **iOS device presets (iPhone / iPad)**: UA + screen swap fine, but `safe-area-inset`, font lists, and some `window.matchMedia` viewport queries will leak. Mac presets are more reliable.

For mid-to-low-adversary scenarios (registering multiple ordinary SaaS accounts, blocking site behavior tracking, preventing cross-site device identification, personal multi-account workflows), the current isolation level is generally sufficient.

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

- [ ] HTTP header `Accept-Language` / `Sec-CH-UA` sub-request coverage (not just main request)
- [ ] `screen` getter via `Object.defineProperty` on Worker scope (if WKWebView allows)
- [ ] Per-profile proxy (HTTP / SOCKS5)
- [ ] Fingerprint template import / export (community sharing)
- [ ] Profile backup / restore (cookie export + fingerprint export framework already in place; end-to-end not complete)

## License

MIT.

## Related Project

- [chatgpt-web-desktop](https://github.com/GravityPoet/chatgpt-web-desktop) — the upstream project this was split off from, focused on the ChatGPT macOS client.
