**English** | [中文](README.zh-CN.md)

# Multi-Profile Anti-Detect Browser

Free, open-source, macOS-native anti-detect browser. Each profile is a fully
isolated Camoufox (Firefox-patched) instance with its own fingerprint, proxy,
cookies, and storage. Free alternative to Multilogin / GoLogin / AdsPower
for personal multi-account workflows.

`v1.2.0` is a full rewrite. The previous WKWebView-based privacy shell is
preserved on the `legacy-wkwebview-cef` branch.

## What Changed in 1.2.0

| | v1.1 (WKWebView) | v1.2.0 (Camoufox) |
|---|---|---|
| Engine | macOS WKWebView | Camoufox v150 (Firefox-patched) |
| TLS / JA3 / JA4 fingerprint | not modified | inherited from Firefox + NSS |
| HTTP/2 frame order / ALPS | not modified | inherited from Firefox |
| Canvas / WebGL / Audio noise | JS-hook based | C++ patches in Camoufox |
| `navigator.*` spoofing | JS hooks (toString-detectable) | binary-level, undetectable |
| Per-profile proxy | best-effort | real Firefox `network.proxy.*` prefs |
| User agent → screen → timezone coherence | mac/iOS family only | bundled v150 preset DB |

This is the first version that can plausibly stand in for a commercial
anti-detect browser in mid-adversary scenarios.

## How It Works

1. The app downloads Camoufox v150 (≈300 MB) into
   `~/Library/Application Support/MultiProfileFingerprintBrowser/runtime/` on
   first use. The archive is SHA256-verified against the upstream release.
2. Each profile is one row in the list, persisted as
   `profiles/<uuid>/meta.json`.
3. When you press **Launch**, the app:
   - Writes a per-profile Firefox `user.js` with proxy prefs, accept-languages,
     and Marionette settings.
   - JSON-encodes the fingerprint and splits it across `CAMOU_CONFIG_1..N`
     environment variables (the upstream protocol).
   - Spawns Camoufox with `--profile <dir> --no-remote --new-instance`.
4. Camoufox reads the env vars at startup, applies the fingerprint at the
   C++ layer, and writes results to its own profile directory.

The host Swift app never touches Firefox internals at runtime — every spoof
runs inside the patched browser binary.

## Features

### Profile Isolation
- Per-profile Firefox profile directory (`firefox-profile/`)
- Per-profile cookies, localStorage, IndexedDB, cache, history
- Per-profile bookmarks, addons (Firefox-compatible)
- Per-profile launch independence (multiple profiles open simultaneously)

### Fingerprint Spoofing (via Camoufox)
- User Agent + `navigator.platform / oscpu / appVersion`
- `navigator.language / languages` + Firefox `intl.accept_languages`
- `navigator.hardwareConcurrency / deviceMemory / maxTouchPoints`
- `screen.width / height / availWidth / availHeight / colorDepth`
- `window.devicePixelRatio`
- `Intl.DateTimeFormat` timezone + `Date.prototype.getTimezoneOffset`
- WebGL `vendor / renderer` (incl. ANGLE strings on Win/Mac, Mesa on Linux)
- Canvas / WebGL / Audio noise (binary patches, not JS hooks)

### Built-in Presets
7 OS × browser combinations cover the realistic baseline:
- macOS 14 Intel, Apple Silicon (en-US, ja-JP)
- Windows 10, Windows 11 (en-US, en-GB, zh-CN)
- Linux x86_64 (en-US)

Pick one from the dropdown or click **Randomize**.

### Proxy
- Direct, HTTP, SOCKS5
- Username / password fields are persisted locally; automated proxy-auth
  injection is not wired in 1.2.0
- SOCKS5 forces `socks_remote_dns=true` to prevent local DNS leak
- Per-profile — no shared system proxy

### Marionette (optional)
- Toggle per profile
- Allocates a unique TCP port from 2828 at launch
- Compatible with Playwright, Selenium, Marionette-protocol clients

## Honest Comparison

| Capability | This project (v1.2.0) | Multilogin / GoLogin / AdsPower |
|---|---|---|
| Multi-profile isolation | yes | yes |
| Canvas / WebGL / Audio noise | yes (binary) | yes |
| UA / screen / timezone spoof | yes | yes |
| TLS / JA3 / JA4 fingerprint | yes (Firefox baseline) | yes (custom Chromium) |
| HTTP/2 fingerprint | yes (Firefox baseline) | yes |
| `toString` detection defense | yes (binary, not JS) | yes |
| Per-profile proxy | yes | yes |
| Cloud-synced profile vault | no | yes |
| Hosted profile farm | no | yes |
| Mobile UA presets (iPhone/iPad) | no (deferred to 1.3) | yes |
| Price | $0 | from $99/month |

Use this for personal multi-account workflows on a single Mac. Use a
commercial product if you need cloud sync, team sharing, or 100+ concurrent
profiles.

## What This Project Does Not Try to Do

- Chromium engine. Camoufox is Firefox-based by design; sites that
  explicitly require Chrome/WebKit will see a Firefox UA, as expected.
- Cloud profile vault, team workspaces, browser farm rental.
- Windows or Linux host builds (the Camoufox binary itself is multi-platform,
  but this Swift host is macOS-only).
- iPhone / Android device emulation. Mobile presets ship in v1.3 once
  the touch-input / orientation story is finalized.

## Build

```bash
swift build -c release          # SPM build
./packaging/make-app.sh         # Bundle as .app
./packaging/make-dmg.sh         # Build DMG with /Applications symlink
```

Requirements:
- macOS 12+
- Xcode Command Line Tools
- Apple Silicon (`arm64`). Intel host support arrives in 1.2.x.

First launch downloads Camoufox v150 (≈300 MB) once. Cached afterwards.

## Architecture

```
Sources/MultiProfileFingerprintBrowser/
├── main.swift                   AppKit entry, switches to SmokeTest on MPFB_SMOKE=1
├── AppDelegate.swift            NSWindow hosting SwiftUI RootView
├── Localization.swift           t(en, zh) string helper
├── Models/
│   ├── Profile.swift            id, name, fingerprint, proxy, notes
│   ├── Fingerprint.swift        Camoufox dotted-key value map + JSON encode
│   └── ProxyConfig.swift        Direct / HTTP / SOCKS5 + Firefox prefs
├── Managers/
│   ├── AppPaths.swift           ~/Library/Application Support layout
│   ├── ProfileStore.swift       Disk-backed CRUD
│   ├── FingerprintPresets.swift Bundled v150 preset DB
│   ├── PortAllocator.swift      Marionette port allocation (2828+)
│   ├── CamoufoxRuntime.swift    Download / SHA256 / extract
│   └── CamoufoxLauncher.swift   user.js + CAMOU_CONFIG_N + Process.run()
├── Util/
│   ├── SHA256.swift             Streaming hasher
│   ├── Logger.swift             OSLog + stderr
│   └── ZipExtractor.swift       /usr/bin/unzip wrapper
├── ViewModels/AppState.swift    @MainActor ObservableObject
└── Views/                       SwiftUI front-end (RootView, ProfileEditor, …)

Resources/fingerprint-presets-v150.json   Hand-curated 7-entry preset DB
```

## Roadmap

- [x] 1.2.0 — Camoufox engine, real fingerprint spoofing, per-profile proxy
- [ ] 1.2.x — Intel Mac (`x86_64`) host support
- [ ] 1.3 — Mobile presets (iPhone/iPad), Camoufox v151 sync
- [ ] 1.4 — Profile import/export, fingerprint preset sharing
- [ ] 1.5 — Headless / Playwright automation recipes

## License

MIT.

## Credits

- [Camoufox](https://github.com/daijro/camoufox) — the Firefox-patched
  anti-detect browser this project drives. MPL-2.0.
- v1.1 (WKWebView) preserved on branch `legacy-wkwebview-cef`.
