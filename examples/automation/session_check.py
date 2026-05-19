#!/usr/bin/env python3
"""
Demonstrate profile session persistence by writing and reading a cookie.

Usage:
    # From the MPFB UI: select this script and click Run.
    # From the terminal (profile already running):
    eval "$(mpfb-script-env <profile-id>)"
    python3 session_check.py

Requires: pip install marionette-driver
"""

import os
import sys
import time

try:
    from marionette_driver.marionette import Marionette
except ImportError:
    print("Error: marionette-driver not installed.", file=sys.stderr)
    print("Run: pip install marionette-driver", file=sys.stderr)
    sys.exit(1)


def main():
    host = os.environ.get("MPFB_MARIONETTE_HOST", "127.0.0.1")
    port = int(os.environ.get("MPFB_MARIONETTE_PORT", "2828"))

    print(f"Connecting to {host}:{port} ...")
    client = Marionette(host, port=port)
    client.start_session()

    # Navigate to a test domain.
    test_url = "https://example.com"
    print(f"Navigating to {test_url} ...")
    client.navigate(test_url)

    # Write a test cookie.
    cookie_name = "mpfb_session_test"
    cookie_value = f"test_{int(time.time())}"
    print(f"Setting cookie: {cookie_name}={cookie_value}")

    client.execute_script("""
        document.cookie = arguments[0] + "=" + arguments[1] + "; path=/";
    """, script_args=[cookie_name, cookie_value])

    # Read it back.
    stored = client.execute_script("""
        return document.cookie;
    """)
    print(f"Current cookies: {stored}")

    if cookie_name in stored:
        print("PASS: Cookie was written and persists in this profile session.")
    else:
        print("FAIL: Cookie not found after write.", file=sys.stderr)
        sys.exit(1)

    client.delete_session()
    print("Done.")


if __name__ == "__main__":
    main()
