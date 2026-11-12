"""Starts test/server.py, opens /?selftest in headless Chromium, prints the
SELFTEST console lines and exits non-zero on any failure."""
import os
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

server = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py")])
time.sleep(1)
lines, errors = [], []
try:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.on("console", lambda m: lines.append(m.text))
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto("http://127.0.0.1:8000/examples/selftest/index.html?selftest")
        page.wait_for_function("() => true")
        # Event info: dispatch a cancelable keydown on #main.
        time.sleep(0.5)
        prevented = page.evaluate("""() => {
            const e = new KeyboardEvent('keydown', {key: 'x', bubbles: true, cancelable: true});
            document.querySelector('#main').dispatchEvent(e);
            return e.defaultPrevented;
        }""")
        print("keydown defaultPrevented:", prevented)
        page.evaluate("location.hash = '#x'")
        deadline = time.time() + 10
        while time.time() < deadline and not any("SELFTEST DONE" in l for l in lines):
            time.sleep(0.1)
        browser.close()
finally:
    server.terminate()

for line in lines:
    if line.startswith("SELFTEST"):
        print(line)
for error in errors:
    print("PAGE ERROR:", error)
other = [l for l in lines if not l.startswith("SELFTEST")]
for line in other:
    print("console:", line)
required = ["event: key readable", "window listener: hashchange handler ran"]
ok = (any("failed=0" in l for l in lines)
      and all(any(r in l and "PASS" in l for l in lines) for r in required)
      and not any("FAIL" in l for l in lines)
      and not errors and prevented)
sys.exit(0 if ok else 1)
