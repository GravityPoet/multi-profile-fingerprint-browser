#!/usr/bin/env python3
"""
Open a URL and print the page title.

Usage:
    # From the MPFB UI: select this script and click Run.
    # From the terminal (profile already running, env copied from UI):
    python3 open_url.py https://example.com

Requires: pip install marionette-driver
"""

import os
import sys

try:
    from marionette_driver.marionette import Marionette
except ImportError:
    print("Error: marionette-driver not installed.", file=sys.stderr)
    print("Run: pip install marionette-driver", file=sys.stderr)
    sys.exit(1)


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "https://example.com"

    host = os.environ.get("MPFB_MARIONETTE_HOST", "127.0.0.1")
    port = int(os.environ.get("MPFB_MARIONETTE_PORT", "2828"))

    print(f"Connecting to {host}:{port} ...")
    client = Marionette(host, port=port)
    client.start_session()

    print(f"Navigating to {url} ...")
    client.navigate(url)

    title = client.title
    print(f"Page title: {title}")

    client.delete_session()
    print("Done.")


if __name__ == "__main__":
    main()
