# Chromium Fingerprint Browser v2 Experiment

This is the isolated Chromium/CEF-track prototype for `multi-profile-fingerprint-browser`.

It does not modify the stable WKWebView v1 app. The current implementation is a Swift/AppKit shell that launches an installed Chromium-family browser with profile-specific launch state. CEF can later replace the launcher layer without throwing away the profile, proxy, export/import, and risk-check model.

## What Works Now

- Per-profile independent Chromium `--user-data-dir`
- Per-profile homepage
- Per-profile fingerprint preset:
  - User-Agent
  - `Accept-Language` / `--lang`
  - timezone via `TZ` process environment
  - window size
  - device scale factor
  - WebRTC IP policy
- Per-profile proxy launch args:
  - Direct: `--no-proxy-server`
  - System: no proxy override
  - HTTP: `--proxy-server=http://host:port`
  - SOCKS5: `--proxy-server=socks5://host:port`
- Export / import profile config JSON
- Egress IP check through the saved proxy config
- Same-proxy and same-last-IP risk warning
- Local fingerprint test page opened inside the launched Chromium profile

## What This Is Not Yet

- Not a patched Chromium fork
- Not TLS / JA3 / HTTP/2 manipulation
- Not CEF embedding yet
- Not a claim that mobile Chrome presets are low-risk on a desktop Mac

The point of this phase is to make the browser-core boundary real: v1 remains WebKit and honest; v2 owns Chromium profile launch, proxy, and user-data isolation.

## Run

```bash
swift build
swift run ChromiumFingerprintBrowser
```

The app searches these executables in order:

- `/Applications/Chromium.app/Contents/MacOS/Chromium`
- `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
- `/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary`
- `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`
- `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge`

To force a specific browser:

```bash
CHROMIUM_EXECUTABLE="/path/to/Chromium" swift run ChromiumFingerprintBrowser
```

## Package

```bash
./packaging/make-app.sh
```

This creates:

```text
dist/Chromium Fingerprint Browser v2.app
```

## Storage

Profile config and Chromium user data are stored under:

```text
~/Library/Application Support/local.multi-profile-fingerprint-browser.chromium-v2/
```

Each profile gets:

```text
profiles/<profile-id>/user-data/
```

That is the core v2 isolation boundary.
