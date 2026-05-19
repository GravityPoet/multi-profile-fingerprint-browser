# Automation Examples

Ready-to-run scripts for use with MPFB's Script Runner or from the terminal.

## Prerequisites

```bash
pip install marionette-driver
```

## How to Use

### From the MPFB UI

1. Launch a profile with Marionette enabled.
2. Select the profile in the sidebar.
3. In the **Script Runner** section, click **Select script** and pick one of
   these `.py` files.
4. Click **Run**. Output appears in the logs directory shown after the run.

### From the Terminal

Copy the script environment from the profile's Automation section, then:

```bash
eval "$(pbpaste)"   # if you just copied the env
python3 open_url.py https://example.com
```

## Examples

| Script | What it does |
|--------|--------------|
| `open_url.py` | Opens a URL and prints the page title. |
| `session_check.py` | Writes and reads a test cookie to prove profile session persistence. |
| `screenshot_page.py` | Saves a screenshot of the current page to `~/Desktop/`. |

## Intended Use

These examples are for:

- **QA testing** of web applications you develop or maintain.
- **Authorized automation** of repetitive personal workflows on sites you
  have permission to automate.
- **Demonstrating** how MPFB's Marionette endpoint works.

## What These Examples Do NOT Do

- No CAPTCHA solving or bypass.
- No anti-bot/anti-abuse evasion.
- No bulk account creation or registration automation.
- No credential stuffing or credential testing.
- No scraping at scale against terms of service.

If you need automation for legitimate QA, consider extending these examples
with your own test assertions and cleanup logic.

## Output Location

All examples write output (screenshots, logs) to the user's Desktop or
Application Support directory — never to the repository checkout.
