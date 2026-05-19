# Chromium/CDP Engine Evaluation

This document evaluates the feasibility of adding an optional Chromium/CDP
engine alongside the current Camoufox (Firefox) engine.

## Current State

- **Engine**: Camoufox (Firefox-based, privacy-focused fork)
- **Automation**: Firefox Marionette protocol
- **Profile isolation**: Per-profile `firefox-profile` directory + `user.js`

## CloakBrowser Analysis

### What CloakBrowser Provides

CloakBrowser is a commercial anti-detect browser built on Chromium. Its
key capabilities:

- Multiple browser profiles with isolated fingerprints
- Chromium-based rendering (sites see Chrome, not Firefox)
- Per-profile proxy configuration
- Cookie/session persistence per profile
- Team collaboration features (cloud sync)

### CloakBrowser-Manager

An open-source companion tool that provides:

- Profile management API
- Browser launch orchestration
- Import/export of profiles

### Binary Distribution Risk

CloakBrowser ships its own patched Chromium binary. Key concerns:

1. **License**: Chromium is BSD-licensed, but patches may include
   proprietary code. Redistribution rights unclear.
2. **Binary size**: ~200-400 MB per platform per version.
3. **Update burden**: Security patches require rebuilding.
4. **Trust**: Users must trust the binary hasn't been tampered with.

## Three Approaches

### A: Adopt (Bundle CloakBrowser Binary)

**Pros**:
- Immediate Chromium fingerprint spoofing
- Battle-tested anti-detect features

**Cons**:
- License/redistribution risk
- Binary trust problem
- Update maintenance burden
- Bloats app size significantly
- Users can't verify what's running

**Verdict**: Not recommended for v1.x. License and trust issues unresolved.

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
| 2026-05-19 | Short-term: no Chromium binary | License unresolved, team size insufficient |
| 2026-05-19 | Medium-term: user-provided CDP | Best capability/complexity ratio |
| 2026-05-19 | Long-term: own patches deferred | Needs dedicated Chromium team |
