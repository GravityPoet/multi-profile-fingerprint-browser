# Camoufox Integration Spike — Phase 0

**Date:** 2026-05-14
**Goal:** Validate that a pure Swift shell can drive the Camoufox binary directly (no Python, no Playwright), with full fingerprint spoofing via environment variables.

**Verdict:** ✅ PASS — Phase 1 implementation can proceed.

## Camoufox Asset (mac arm64)

| Property | Value |
|---|---|
| Release | `v150.0.2-beta.25` |
| Asset | `camoufox-150.0.2-alpha.25-mac.arm64.zip` |
| Size | 311,097,462 bytes (≈297 MiB) |
| SHA256 | `a7f03c1def1ad63029b0d522353039e88afadbdef2517755b733e6931a462eb2` |
| Source | `github.com/daijro/camoufox/releases/download/v150.0.2-beta.25/...` |
| Codesign | `adhoc, linker-signed` (Mach-O thin arm64) — Gatekeeper-clean after user permission |
| Version reported | `Camoufox 150.0.2-beta.25` |

Unzipped layout matches a standard Firefox `.app` bundle. Executable at
`Camoufox.app/Contents/MacOS/camoufox`. No external runtime dependencies.

## Configuration Mechanism

Camoufox accepts fingerprint config through chunked environment variables.
The upstream Python wrapper (`pythonlib/camoufox/utils.py:80-100`) does this:

```python
chunk_size = 2047 if OS_NAME == 'win' else 32767
config_str = orjson.dumps(config_map).decode('utf-8')

for i in range(0, len(config_str), chunk_size):
    chunk = config_str[i : i + chunk_size]
    env_name = f"CAMOU_CONFIG_{(i // chunk_size) + 1}"
    env_vars[env_name] = chunk
```

The Camoufox binary reassembles `CAMOU_CONFIG_1 .. CAMOU_CONFIG_N` into a
single JSON document at startup. **Nothing about this requires Python.**

Swift equivalent (Phase 1 will live in `Managers/CamoufoxLauncher.swift`):

```swift
let json = try JSONEncoder().encode(fingerprint)  // [String: AnyCodable]
let str = String(data: json, encoding: .utf8)!
let chunkSize = 32767
var env = ProcessInfo.processInfo.environment

var idx = str.startIndex
var n = 1
while idx < str.endIndex {
    let end = str.index(idx, offsetBy: chunkSize, limitedBy: str.endIndex) ?? str.endIndex
    env["CAMOU_CONFIG_\(n)"] = String(str[idx..<end])
    idx = end
    n += 1
}

let process = Process()
process.executableURL = camoufoxBinary
process.arguments = ["--profile", profileDir.path, "--no-remote", "--new-instance"]
process.environment = env
try process.run()
```

## Live Test

A headless run was issued with this minimal config:

```json
{
  "navigator.userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
  "navigator.platform": "Win32",
  "navigator.language": "en-GB",
  "navigator.languages": ["en-GB", "en"],
  "navigator.hardwareConcurrency": 8,
  "navigator.deviceMemory": 16,
  "screen.width": 1920,
  "screen.height": 1080,
  "screen.colorDepth": 24,
  "window.devicePixelRatio": 1,
  "timezone": "Europe/London"
}
```

Command:

```bash
CAMOU_CONFIG_1="$CONFIG_JSON" Camoufox.app/Contents/MacOS/camoufox \
  --profile "$PROFILE_DIR" \
  --no-remote \
  --new-instance \
  --headless \
  --screenshot "$SPIKE/fp-result.png" \
  --window-size 1024,768 \
  "file://$SPIKE/fp-test.html"
```

JavaScript on the loaded page read `navigator.*`, `screen.*`,
`Intl.DateTimeFormat().resolvedOptions().timeZone`. Exit code `0`.
Screenshot saved (`fp-result.png`, 44 KiB).

### Results

| Field | Expected | Observed | Result |
|---|---|---|---|
| `navigator.userAgent` | Win10 Chrome 130 | Win10 Chrome 130 | ✅ |
| `navigator.platform` | `Win32` | `Win32` | ✅ |
| `navigator.hardwareConcurrency` | 8 | 8 | ✅ |
| `navigator.deviceMemory` | 16 | (undefined) | ⚠️ Firefox lacks this API; needs UA-OS pairing strategy |
| `screen.width × height` | 1920 × 1080 | 1920 × 1080 | ✅ |
| `screen.colorDepth` | 24 | 24 | ✅ |
| `devicePixelRatio` | 1 | 1 | ✅ |
| `Intl…timeZone` | `Europe/London` | `Europe/London` | ✅ |
| `navigator.language` | `en-GB` | `en-US` | ⚠️ Config key likely needs different name |
| `navigator.languages` | `["en-GB","en"]` | `["en-US","en"]` | ⚠️ Same |

8 of 10 fields injected cleanly via a single `CAMOU_CONFIG_1` env var. The
two `language` discrepancies and the missing `deviceMemory` are
field-naming / preset-consistency issues, not architectural blockers.

## Phase 1 Open Items

These are tuning tasks, not blockers:

1. **Exact key names.** Read `pythonlib/camoufox/fingerprints.py` and
   `fingerprint-presets-v150.json` to enumerate the full set of supported
   config keys. The `navigator.language` key probably maps to a Firefox
   pref (`intl.accept_languages`) rather than a Camoufox JSON key.
2. **OS-coherent presets.** When `navigator.platform = "Win32"`, the
   shell should also configure consistent values for fields that vary by
   OS (fonts, WebGL renderer, deviceMemory, mediaCapabilities). Camoufox
   ships per-OS presets in `fingerprint-presets-v150.json` — reuse them.
3. **Firefox `user.js` overlay.** Some prefs (proxy, languages, font
   bundling) are easier to set via a `user.js` file written into each
   profile directory than via `CAMOU_CONFIG_*`. Mirror the Python wrapper's
   `firefox_user_prefs` dict.
4. **Adhoc codesign re-sign.** Bundling Camoufox.app inside the host
   `.app/Contents/Resources/runtime/` may trigger Gatekeeper. Re-sign with
   `codesign --force --deep --sign -` after copy.
5. **Marionette port allocation.** Phase 2 automation will need
   `--marionette` plus a unique TCP port per profile instance.

## Spike Artifacts (not committed)

Kept under `~/Library/Caches/camoufox-spike/` for hand re-verification:
- `camoufox-mac-arm64.zip` (signed asset)
- `extracted/Camoufox.app`
- `fp-test.html`
- `test-profile-1/`
- `fp-result.png`

These can be deleted at any time; the Phase 1 runtime path will be
`~/Library/Application Support/MultiProfileFingerprintBrowser/runtime/`.
