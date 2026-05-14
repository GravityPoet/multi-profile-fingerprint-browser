# Chromium Fingerprint Browser v2 Experiment

This is the isolated Chromium/CEF track for `multi-profile-fingerprint-browser`.

It does not modify the stable WKWebView v1 app. The current implementation is a Swift/AppKit shell plus a bundled CEF/Chromium browser component. Opening a profile no longer launches the system Chrome app.

## What Works Now

- Per-profile independent CEF `root_cache_path` / `cache_path`
- Per-profile independent cache / cookies / localStorage
- Per-profile homepage
- Per-profile fingerprint preset:
  - User-Agent
  - `Accept-Language` / `--lang`
  - timezone via `TZ` process environment
  - screen preset for diagnostics and consistency checks
  - device scale factor
  - WebRTC IP policy
- CEF browser window bounds are saved per profile, so the browser is not forced back to one fixed size on every launch.
- Per-profile proxy in that profile's CEF process:
  - Direct: CEF `no-proxy-server`
  - System: no proxy override
  - HTTP: CEF `proxy-server=http://host:port`
  - SOCKS5: CEF `proxy-server=socks5://host:port`
- Export / import profile config JSON
- Egress IP check through the saved proxy config
- Same-proxy and same-last-IP risk warning
- Local fingerprint test page opened inside the launched CEF profile

## What This Is Not Yet

- Not a patched Chromium fork
- Not TLS / JA3 / HTTP/2 manipulation
- Not Electron
- Does not launch system Chrome / Chromium
- Not a claim that mobile Chrome presets are low-risk on a desktop Mac

The point of this phase is to make the browser-core boundary real: v1 remains WebKit and honest; v2 owns CEF/Chromium profile, proxy, and data-directory isolation.

## Run

```bash
swift build
swift run ChromiumFingerprintBrowser
```

Plain `swift run` only runs the Swift shell. Build the CEF component first before opening pages; the packaging script does this automatically.

Force a CEF component during development:

```bash
MPFB_CEF_EXECUTABLE="/path/to/ChromiumFingerprintCEF" swift run ChromiumFingerprintBrowser
```

## Package

```bash
./packaging/make-app.sh
```

This creates:

```text
dist/Chromium Fingerprint Browser v2.app
```

The first package build downloads the official macOS CEF binary distribution into `cef/third_party/`. That directory is intentionally ignored by Git.

## Storage

Profile config and CEF user data are stored under:

```text
~/Library/Application Support/local.multi-profile-fingerprint-browser.chromium-v2/
```

Each profile gets:

```text
profiles/<profile-id>/user-data/
profiles/<profile-id>/cef-window-bounds.txt
```

That is the core v2 isolation boundary.
