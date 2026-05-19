# Automation Mode

Automation Mode borrows the useful part of CloakBrowser's workflow: every
running profile exposes a script-friendly control surface while the real
browser window stays visible for inspection and manual handoff.

It is not a CAPTCHA bypass feature and does not promise to defeat anti-abuse
systems. Use it for local testing, repetitive personal workflows, QA, and
authorized browser automation.

## Current Engine

`v1.2.x` uses Camoufox, so the automation transport is Firefox Marionette.

1. Edit a profile.
2. Enable **Marionette (remote control)**.
3. Launch the profile.
4. Copy the endpoint or script environment from the Automation section.

The app keeps the normal Camoufox window open. If a script fails, you can inspect
the live state instead of losing the session.

## Exported Environment

The UI can copy shell-ready variables for a running profile:

```bash
MPFB_FIREFOX_PROFILE_DIR='/Users/.../firefox-profile'
MPFB_MARIONETTE_ENDPOINT='127.0.0.1:2828'
MPFB_MARIONETTE_HOST='127.0.0.1'
MPFB_MARIONETTE_PORT='2828'
MPFB_PROCESS_ID='12345'
MPFB_PROFILE_DIR='/Users/.../profiles/<uuid>'
MPFB_PROFILE_ID='<uuid>'
MPFB_PROFILE_NAME='Profile 1'
```

## Connecting to a Running Profile

There are two approaches. They are **not** the same thing.

### Approach A: Raw Marionette client (attach to the running instance)

Connect directly to the Marionette endpoint shown in the UI. The browser
process stays alive; the client sends commands over the existing TCP socket.

```python
# Requires: pip install marionette-driver
import os
from marionette_driver.marionette import Marionette

port = int(os.environ["MPFB_MARIONETTE_PORT"])
client = Marionette("localhost", port=port)
client.start_session()
client.navigate("https://example.com")
print(client.title)
```

This is the intended way to script the profile that MPFB already launched.
The browser window remains visible and manually controllable.

### Approach B: Selenium / geckodriver (spawns a separate Firefox)

Selenium launches its **own** Firefox process using the same profile directory.
It does **not** attach to the already-running Camoufox window. Two Firefox
instances using the same profile directory simultaneously will corrupt session
data — do not run both at the same time.

```bash
python3 -m pip install selenium
brew install geckodriver
```

```python
#!/usr/bin/env python3
import os
from selenium import webdriver
from selenium.webdriver.firefox.options import Options

profile_dir = os.environ["MPFB_FIREFOX_PROFILE_DIR"]

options = Options()
options.profile = profile_dir
# Stop the MPFB-launched profile first to avoid profile directory conflicts.
driver = webdriver.Firefox(options=options)
driver.get("https://example.com")
print(driver.title)
driver.quit()
```

Choose Approach A when you want to script the window you can already see.
Choose Approach B when you need full WebDriver control and do not need the
MPFB window.

## Roadmap

- Script runner panel with stdout/stderr logs.
- Per-profile automation locks to avoid two scripts controlling the same
  browser at once.
- Failure handoff: keep browser open and show last command/error.
- Optional Chromium/CDP engine after license and binary distribution review.
