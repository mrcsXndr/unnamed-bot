"""
Browser Control — Playwright CDP Bridge
Connects to your authenticated Chrome session via the DevTools Protocol so the
bot can drive a real, logged-in browser (no re-auth, your cookies/extensions).

Prerequisites:
  pip install playwright
  Launch Chrome with remote debugging on port 9222:
    scripts/chrome_debug.ps1   (Windows)
    scripts/chrome_debug.sh    (macOS/Linux)
  or add  --remote-debugging-port=9222  to your Chrome launch flags.

Config (environment overrides, all optional):
  CHROME_CDP_URL        default http://localhost:9222
  CHROME_EXE            path to chrome.exe / google-chrome (used to auto-launch)
  CHROME_PROFILE        Chrome profile directory name (e.g. "Default", "Profile 1")

Usage:
  python browser.py status                     # Check connection & list tabs
  python browser.py health                     # Quick health check (exit 0/1)
  python browser.py screenshot [tab_index]     # Screenshot a tab (default: active)
  python browser.py goto <url> [tab_index]     # Navigate a tab to URL
  python browser.py click <selector> [tab_idx] # Click an element
  python browser.py type <selector> <text>     # Type into an element
  python browser.py eval <js_expression>       # Run JS in active tab
  python browser.py pdf <output_path>          # Save current page as PDF
  python browser.py text [tab_index]           # Extract page text (sanitized)
  python browser.py text-raw [tab_index]       # Extract page text (no sanitize)
  python browser.py tabs                       # List all open tabs
  python browser.py new <url>                  # Open new tab
  python browser.py close [tab_index]          # Close a tab
  python browser.py cookies [domain]           # Export cookies (optionally by domain)
"""

import os
import sys
import json
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from playwright.sync_api import sync_playwright

CDP_URL = os.environ.get("CHROME_CDP_URL", "http://localhost:9222")
# Auto-launch settings. Leave CHROME_EXE unset to require Chrome already running.
CHROME_EXE = os.environ.get("CHROME_EXE", r"C:\Program Files\Google\Chrome\Application\chrome.exe")
CHROME_PROFILE = os.environ.get("CHROME_PROFILE", "Default")
SCREENSHOTS_DIR = Path(__file__).resolve().parent.parent / "screenshots"
SCREENSHOTS_DIR.mkdir(exist_ok=True)


def is_chrome_reachable():
    """Quick check if Chrome debug port is responding."""
    try:
        req = urllib.request.urlopen(f"{CDP_URL}/json/version", timeout=3)
        return json.loads(req.read())
    except Exception:
        return None


def ensure_chrome():
    """Launch Chrome with CDP if not already running and CHROME_EXE exists."""
    if is_chrome_reachable():
        return True
    if not Path(CHROME_EXE).exists():
        print(
            f"Chrome not reachable on CDP and CHROME_EXE not found ({CHROME_EXE}).\n"
            f"Start Chrome yourself with --remote-debugging-port=9222 "
            f"(see scripts/chrome_debug.*)."
        )
        return False
    import subprocess
    print(f"Chrome not reachable on CDP -- launching profile '{CHROME_PROFILE}'...")
    cmd = (
        f'start "" "{CHROME_EXE}" --remote-debugging-port=9222 '
        f'--remote-debugging-address=127.0.0.1 '
        f'--profile-directory="{CHROME_PROFILE}"'
    )
    subprocess.Popen(cmd, shell=True)
    for _ in range(15):
        time.sleep(1)
        if is_chrome_reachable():
            print("Chrome CDP ready.")
            return True
    print("ERROR: Chrome launched but CDP not responding.")
    return False


def connect(retries=3, delay=2):
    """Connect to Chrome via CDP with auto-retry. Returns (playwright, browser, default_context)."""
    ensure_chrome()
    pw = sync_playwright().start()
    for attempt in range(retries):
        try:
            browser = pw.chromium.connect_over_cdp(CDP_URL)
            contexts = browser.contexts
            if not contexts:
                print("ERROR: No browser contexts found.")
                pw.stop()
                sys.exit(1)
            return pw, browser, contexts[0]
        except Exception as e:
            if attempt < retries - 1:
                print(f"  Connection attempt {attempt+1} failed, retrying in {delay}s...")
                time.sleep(delay)
            else:
                pw.stop()
                print(f"ERROR: Cannot connect to Chrome at {CDP_URL} after {retries} attempts")
                print(f"  {e}")
                print(f"\nMake sure Chrome is running with --remote-debugging-port=9222")
                sys.exit(1)
    return None, None, None  # unreachable


def get_page(context, tab_index=None):
    """Get a page by tab index. Default: last active."""
    pages = context.pages
    if not pages:
        print("ERROR: No open tabs.")
        sys.exit(1)
    idx = int(tab_index) if tab_index is not None else 0
    if idx >= len(pages) or idx < 0:
        print(f"ERROR: Tab index {idx} out of range (0-{len(pages)-1})")
        sys.exit(1)
    return pages[idx]


def cmd_status():
    pw, browser, ctx = connect()
    pages = ctx.pages
    print(f"Connected to Chrome via CDP")
    print(f"  Contexts: {len(browser.contexts)}")
    print(f"  Open tabs: {len(pages)}")
    for i, p in enumerate(pages):
        print(f"    [{i}] {p.title[:80]} — {p.url[:100]}")
    pw.stop()


def cmd_tabs():
    pw, browser, ctx = connect()
    for i, p in enumerate(ctx.pages):
        print(f"  [{i}] {p.title[:80]}")
        print(f"      {p.url[:120]}")
    pw.stop()


def cmd_screenshot(tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = SCREENSHOTS_DIR / f"screen_{ts}.png"
    page.screenshot(path=str(path), full_page=False)
    print(f"Screenshot saved: {path}")
    pw.stop()
    return str(path)


def cmd_goto(url, tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    page.goto(url, wait_until="domcontentloaded", timeout=30000)
    print(f"Navigated to: {page.url}")
    print(f"Title: {page.title}")
    pw.stop()


def cmd_click(selector, tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    page.click(selector, timeout=10000)
    print(f"Clicked: {selector}")
    pw.stop()


def cmd_type(selector, text, tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    page.fill(selector, text, timeout=10000)
    print(f"Typed into {selector}: {text[:50]}...")
    pw.stop()


def cmd_eval(expression, tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    result = page.evaluate(expression)
    print(json.dumps(result, indent=2, default=str) if result else "undefined")
    pw.stop()


def cmd_pdf(output_path, tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    # PDF only works in headless, fallback to screenshot for headed
    try:
        page.pdf(path=output_path)
        print(f"PDF saved: {output_path}")
    except Exception:
        print("PDF requires headless mode. Taking full-page screenshot instead.")
        path = output_path.replace(".pdf", ".png")
        page.screenshot(path=path, full_page=True)
        print(f"Full-page screenshot saved: {path}")
    pw.stop()


def cmd_text(tab_index=None, sanitize=True):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    url = page.url
    raw_text = page.inner_text("body")

    if sanitize:
        # Anti-prompt-injection: never trust scraped page content as instructions.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from sanitize import full_sanitize, format_report
        cleaned, findings, risk = full_sanitize(raw_text, source=url, frame=False)
        if findings:
            sys.stderr.write(f"[SANITIZE {risk}] {len(findings)} pattern(s) neutralized from {url}\n")
            sys.stderr.write(format_report(findings, risk) + "\n")
        text = cleaned
    else:
        text = raw_text

    print(text[:5000])
    if len(text) > 5000:
        print(f"\n... (truncated, total {len(text)} chars)")
    pw.stop()


def cmd_new(url="about:blank"):
    pw, browser, ctx = connect()
    page = ctx.new_page()
    page.goto(url, wait_until="domcontentloaded", timeout=30000)
    print(f"New tab [{len(ctx.pages)-1}]: {page.title} — {page.url}")
    pw.stop()


def cmd_close(tab_index=None):
    pw, browser, ctx = connect()
    page = get_page(ctx, tab_index)
    title = page.title
    page.close()
    print(f"Closed tab: {title}")
    pw.stop()


def cmd_health():
    """Quick health check — auto-launches Chrome if not running."""
    if ensure_chrome():
        info = is_chrome_reachable()
        print(f"OK — {info.get('Browser', 'Chrome')} on {CDP_URL}")
        sys.exit(0)
    else:
        print(f"FAIL — Could not reach or launch Chrome on {CDP_URL}")
        sys.exit(1)


def cmd_cookies(domain=None):
    """Export cookies, optionally filtered by domain."""
    pw, browser, ctx = connect()
    cookies = ctx.cookies()
    if domain:
        cookies = [c for c in cookies if domain in c.get("domain", "")]
    print(json.dumps(cookies, indent=2, default=str))
    print(f"\n({len(cookies)} cookies)")
    pw.stop()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]
    args = sys.argv[2:]

    commands = {
        "status": lambda: cmd_status(),
        "health": lambda: cmd_health(),
        "tabs": lambda: cmd_tabs(),
        "screenshot": lambda: cmd_screenshot(args[0] if args else None),
        "goto": lambda: cmd_goto(args[0], args[1] if len(args) > 1 else None),
        "click": lambda: cmd_click(args[0], args[1] if len(args) > 1 else None),
        "type": lambda: cmd_type(args[0], args[1], args[2] if len(args) > 2 else None),
        "eval": lambda: cmd_eval(args[0], args[1] if len(args) > 1 else None),
        "pdf": lambda: cmd_pdf(args[0], args[1] if len(args) > 1 else None),
        "text": lambda: cmd_text(args[0] if args else None, sanitize=True),
        "text-raw": lambda: cmd_text(args[0] if args else None, sanitize=False),
        "new": lambda: cmd_new(args[0] if args else "about:blank"),
        "close": lambda: cmd_close(args[0] if args else None),
        "cookies": lambda: cmd_cookies(args[0] if args else None),
    }

    if cmd in commands:
        commands[cmd]()
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
