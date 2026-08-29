"""Run the built Flutter web client through local ChromeDriver and stub API."""
from __future__ import annotations

import json
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def call(url: str, payload: dict | None = None) -> dict:
    request = urllib.request.Request(url, method="POST" if payload is not None else "GET")
    if payload is not None:
        request.data = json.dumps(payload).encode()
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    processes = [
        subprocess.Popen(["python3", "-m", "http.server", "4173", "-d", "client/build/web"], cwd=ROOT),
        subprocess.Popen(["python3", "scripts/e2e_stub_backend.py", "--port", "8080"], cwd=ROOT),
        subprocess.Popen(["/usr/bin/chromedriver", "--port=4444"], cwd=ROOT),
    ]
    session = None
    try:
        time.sleep(2)
        result = call("http://127.0.0.1:4444/session", {"capabilities": {"alwaysMatch": {
            "browserName": "chrome",
            "goog:chromeOptions": {"binary": "/usr/bin/chromium", "args": ["--headless=new", "--no-sandbox"]},
        }}})
        session = result.get("sessionId") or result.get("value", {}).get("sessionId")
        if not session:
            raise RuntimeError(f"ChromeDriver session failed: {result}")
        base = f"http://127.0.0.1:4444/session/{session}"
        call(f"{base}/url", {"url": "http://127.0.0.1:4173"})
        time.sleep(15)
        call(
            f"{base}/execute/sync",
            {"script": "document.querySelector('flt-semantics-placeholder')?.click();", "args": []},
        )
        time.sleep(2)
        result = call(f"{base}/execute/sync", {"script": "return document.body.innerText;", "args": []})
        body = result["value"]
        required = ["Bridge connected", "Send"]
        missing = [text for text in required if text not in body]
        if missing:
            raise RuntimeError(f"missing UI text: {missing}; body={body[:500]!r}")
        result = call(f"{base}/execute/async", {"script": """
            const done = arguments[arguments.length - 1];
            const input = document.querySelector('textarea[aria-label="Message ChatGPT"]');
            const send = [...document.querySelectorAll('[role="button"]')].find(e => e.innerText === 'Send');
            if (!input || !send) { done('missing composer or send'); return; }
            input.focus();
            done('ready');
        """, "args": []})
        if result["value"] != "ready":
            raise RuntimeError(f"composer interaction failed: {result}")
        element = call(f"{base}/elements", {"using": "css selector", "value": "textarea[aria-label='Message ChatGPT']"})["value"][-1]
        element_id = next(iter(element.values()))
        call(f"{base}/element/{element_id}/click", {})
        key_actions = []
        for character in "Browser E2E ping":
            key_actions.extend([{"type": "keyDown", "value": character}, {"type": "keyUp", "value": character}])
        key_actions.extend([{"type": "keyDown", "value": "\uE007"}, {"type": "keyUp", "value": "\uE007"}])
        call(f"{base}/actions", {"actions": [{"type": "key", "id": "keyboard", "actions": key_actions}]})
        send = call(f"{base}/elements", {"using": "xpath", "value": "//*[local-name()='flt-semantics' and @role='button' and normalize-space()='Send']"})["value"][0]
        send_id = next(iter(send.values()))
        call(f"{base}/element/{send_id}/click", {})
        time.sleep(10)
        body = call(f"{base}/execute/sync", {"script": "return document.body.innerText;", "args": []})["value"]
        if "Browser E2E ping" not in body:
            raise RuntimeError(f"sent prompt missing after send: {body[-500:]!r}")
        conversations = call("http://127.0.0.1:8080/v1/conversations")["data"]
        latest_id = next(item["id"] for item in conversations if item["title"] == "Browser E2E ping")
        conversation = call(f"http://127.0.0.1:8080/v1/conversations/{latest_id}")["data"]
        if not any(message.get("text") == "Stub reply: Browser E2E ping" for message in conversation["messages"]):
            raise RuntimeError(f"stub response missing: {conversation!r}")
        print("local webdriver E2E passed: render, compose, send, and backend reply")
        return 0
    finally:
        if session:
            try:
                call(f"http://127.0.0.1:4444/session/{session}")
            except OSError:
                pass
        for process in processes:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
