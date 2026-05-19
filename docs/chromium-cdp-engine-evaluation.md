# Chromium/CDP Engine Evaluation

This document evaluates the feasibility of adding an optional Chromium/CDP
engine alongside the current Camoufox (Firefox) engine.

## Current State

- **Engine**: Camoufox (Firefox-based, privacy-focused fork)
- **Automation**: Firefox Marionette protocol
- **Profile isolation**: Per-profile `firefox-profile` directory + `user.js`

## CloakBrowser Analysis

### What CloakBrowser Is

CloakBrowser is a stealth Chromium binary with source-level C++ fingerprint
patches. It is a drop-in Playwright/Puppeteer replacement — same API, just
swap the import.

Key characteristics:

- **Stealth Chromium binary** with fingerprints modified at C++ source level
  (canvas, WebGL, audio, fonts, GPU, screen, automation signals, etc.)
- **Multiple source-level patches** compiled into the binary, not JavaScript
  injection (patch count varies by release; see upstream README)
- **Auto-downloads** the binary on first use (`pip install cloakbrowser`)
- **0.9 reCAPTCHA v3 score**, passes Cloudflare Turnstile, FingerprintJS
- **`humanize=True`** flag for human-like mouse/keyboard/scroll behavior

### License Structure

CloakBrowser has a dual-license structure:

- **Python/JS wrapper**: MIT license, open source
- **Chromium binary**: Free to use, but redistribution is restricted per
  `BINARY-LICENSE` in the repository. Bundling the binary in our release
  requires explicit verification of redistribution rights.

### CloakBrowser-Manager (Separate Project)

A **companion project** (Docker-based) providing:

- Web GUI for managing browser profiles (similar to Multilogin/GoLogin)
- Docker Hub image with noVNC for visual inspection
- Profile persistence and isolation

This is a separate tool, not part of the core CloakBrowser package.

### Binary Distribution Risk

CloakBrowser ships a custom Chromium binary (~200-400 MB). Key concerns:

1. **License**: The Python/JS wrapper is MIT, but the binary itself is
   governed by a separate `BINARY-LICENSE` that restricts redistribution.
   Bundling requires explicit permission or a legal review.
2. **Binary trust**: Users must trust the pre-built binary hasn't been
   tampered with. No reproducible build process documented.
3. **Update burden**: Binary auto-updates, but bundling means we'd need
   to track upstream releases.
4. **Size**: ~200-400 MB per platform per version.

## Three Approaches

### A: Adopt (Bundle CloakBrowser Binary)

**Pros**:
- Immediate Chromium fingerprint spoofing (source-level patches)
- Drop-in Playwright/Puppeteer replacement

**Cons**:
- Binary redistribution restricted per BINARY-LICENSE; needs verification
- Binary trust problem (no reproducible build)
- ~200-400 MB per platform
- Auto-update mechanism may conflict with bundling

**Verdict**: Promising, but redistribution and trust issues need resolution
before bundling. Could work as optional download.

### B: Wrap (User-Provided CDP Browser)

Allow users to point MPFB at any CDP-compatible browser binary they
already have installed (Chrome, Chromium, Edge, Brave).

**Pros**:
- No binary redistribution
- Users control their own browser trust
- Smaller app footprint
- Leverages existing browser installations

**Cons**:
- No fingerprint spoofing (stock Chrome leaks real fingerprint)
- Different binaries have different CDP versions
- User must install browser separately
- Testing matrix grows (Chrome stable/beta/canary, Edge, etc.)

**Verdict**: Recommended for medium-term. Good balance of capability
and simplicity.

### C: Build (Maintain Own Chromium Patch)

Fork Chromium, apply fingerprint spoofing patches, maintain our own
binary distribution.

**Pros**:
- Full control over fingerprint spoofing
- Can match CloakBrowser capabilities
- Single binary to test against

**Cons**:
- Enormous maintenance burden (Chromium releases ~every 4 weeks)
- Requires dedicated team for security patches
- Build infrastructure cost (CI for 3 platforms)
- Legal review needed for patch distribution

**Verdict**: Not recommended for current team size. Consider only if
the project reaches sufficient scale.

## Recommended Roadmap

### Short-term (v1.2-v1.3)

- Do NOT bundle CloakBrowser binary
- Continue with Camoufox as default engine
- Focus on Script Runner and automation workflow maturity

### Medium-term (v1.4-v1.5)

- Add `BrowserEngine` enum: `.camoufox`, `.chromiumCDP`
- Profile gets `engine` field (default: `.camoufox`)
- Support "user-provided CDP binary" path:
  - User specifies path to Chrome/Chromium/Edge binary
  - MPFB launches with `--remote-debugging-port=<port>`
  - Per-profile `user-data-dir` for isolation
  - CDP endpoint exposed similar to Marionette endpoint
- Script Runner injects `MPFB_CDP_ENDPOINT` for Chromium profiles
- Playwright examples for Chromium engine

### Long-term (v2.0+)

- Evaluate maintaining own Chromium patches if team grows
- Consider CloakBrowser integration only if license clarifies
- Potential Playwright-first architecture with engine abstraction

## Architecture Notes

### BrowserEngine Abstraction

```swift
enum BrowserEngine: String, Codable {
    case camoufox
    case chromiumCDP
}

struct Profile {
    // ... existing fields ...
    var engine: BrowserEngine = .camoufox  // default for migration
}
```

### CDP Endpoint Format

For Chromium profiles, the endpoint would be:
```
127.0.0.1:<debugging-port>
```

Playwright connection:
```python
browser = playwright.chromium.connect_over_cdp("http://127.0.0.1:<port>")
```

### Profile Migration

Existing profiles (no `engine` field) default to `.camoufox`.
No data migration needed — field is optional with sensible default.

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-19 | Short-term: no Chromium binary | Redistribution rights unverified, trust model unclear |
| 2026-05-19 | Medium-term: user-provided CDP or optional CloakBrowser download | Best capability/complexity ratio |
| 2026-05-19 | Long-term: evaluate bundling CloakBrowser | Needs redistribution verification, reproducible build |
