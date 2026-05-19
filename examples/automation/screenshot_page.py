#!/usr/bin/env python3
"""
Save a screenshot of the current page to the user's output directory.

Usage:
    # From the MPFB UI: select this script and click Run.
    # From the terminal (profile already running, env copied from UI):
    python3 screenshot_page.py [output_path]

Output defaults to ~/Desktop/mpfb-screenshot-<timestamp>.png.
Requires: pip install marionette-driver
"""

import os
import sys
import time
from pathlib import Path

try:
    from marionette_driver.marionette import Marionette
except ImportError:
    print("Error: marionette-driver not installed.", file=sys.stderr)
    print("Run: pip install marionette-driver", file=sys.stderr)
    sys.exit(1)


def main():
    host = os.environ.get("MPFB_MARIONETTE_HOST", "127.0.0.1")
    port = int(os.environ.get("MPFB_MARIONETTE_PORT", "2828"))

    # Determine output path.
    if len(sys.argv) > 1:
        output_path = Path(sys.argv[1])
    else:
        timestamp = int(time.time())
        desktop = Path.home() / "Desktop"
        output_path = desktop / f"mpfb-screenshot-{timestamp}.png"

    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Connecting to {host}:{port} ...")
    client = Marionette(host, port=port)
    client.start_session()

    # Navigate if no page loaded yet.
    url = client.get_url()
    if not url or url == "about:blank":
        print("Navigating to example.com for demo ...")
        client.navigate("https://example.com")

    print(f"Taking screenshot ...")
    png_data = client.screenshot()

    # Marionette returns base64-encoded PNG.
    import base64
    raw = base64.b64decode(png_data)
    output_path.write_bytes(raw)

    print(f"Screenshot saved to: {output_path}")
    print(f"Size: {len(raw)} bytes")

    client.delete_session()
    print("Done.")


if __name__ == "__main__":
    main()
