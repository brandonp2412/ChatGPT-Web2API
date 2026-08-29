from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client"
STUB_PORT = int(os.environ.get("SLOPPA_E2E_PORT", "18080"))
STUB_URL = f"http://127.0.0.1:{STUB_PORT}"
WEBDRIVER_PORT = int(os.environ.get("SLOPPA_WEBDRIVER_PORT", "4444"))
WEBDRIVER_URL = f"http://127.0.0.1:{WEBDRIVER_PORT}"


def _find_executable(env_name: str, candidates: list[str]) -> str:
    configured = os.environ.get(env_name)
    if configured:
        return configured
    for candidate in candidates:
        expanded = str(Path(candidate).expanduser())
        if Path(expanded).is_file() and os.access(expanded, os.X_OK):
            return expanded
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    raise RuntimeError(f"Could not find executable for {env_name}")


def _wait_for_http(
    process: subprocess.Popen[bytes],
    url: str,
    label: str,
    timeout: float = 10.0,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"{label} exited early with code {process.returncode}")
        try:
            with urllib.request.urlopen(url, timeout=0.5) as response:
                if 200 <= response.status < 500:
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"{label} did not become ready")


def _stop_process(process: subprocess.Popen[bytes], label: str) -> None:
    if process.poll() is None:
        process.terminate()
    try:
        output, _ = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate(timeout=3)
    if label == "e2e-stub" and output:
        sys.stderr.write(f"[{label}]\n{output.decode(errors='replace')}")
    elif process.returncode not in (0, -15) and output:
        sys.stderr.write(f"[{label}]\n{output.decode(errors='replace')}")


def main() -> int:
    flutter = _find_executable(
        "FLUTTER_BIN",
        ["~/.local/flutter/bin/flutter", "~/.local/opt/flutter/bin/flutter", "flutter"],
    )
    chrome = _find_executable(
        "CHROME_EXECUTABLE",
        ["/usr/bin/chromium", "/usr/bin/brave", "chromium", "google-chrome"],
    )
    chromedriver = _find_executable(
        "CHROMEDRIVER_BIN",
        ["/usr/bin/chromedriver", "chromedriver"],
    )
    python = str(ROOT / ".venv" / "bin" / "python")
    if not Path(python).is_file():
        python = sys.executable

    stub = subprocess.Popen(
        [python, str(ROOT / "scripts" / "e2e_stub_backend.py"), "--port", str(STUB_PORT)],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    driver: subprocess.Popen[bytes] | None = None
    try:
        _wait_for_http(stub, f"{STUB_URL}/health", "E2E stub")
        driver = subprocess.Popen(
            [chromedriver, f"--port={WEBDRIVER_PORT}"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        _wait_for_http(driver, f"{WEBDRIVER_URL}/status", "ChromeDriver")

        env = os.environ.copy()
        env["CHROME_EXECUTABLE"] = chrome
        command = [
            flutter,
            "drive",
            "--driver=test_driver/integration_test.dart",
            "--target=integration_test/web_e2e_test.dart",
            "-d",
            "chrome",
            "--driver-port",
            str(WEBDRIVER_PORT),
            "--headless",
            "--chrome-binary",
            chrome,
            f"--dart-define=SLOPPA_BRIDGE_URL={STUB_URL}",
        ]
        completed = subprocess.run(command, cwd=CLIENT, env=env, check=False)
        return completed.returncode
    finally:
        if driver is not None:
            _stop_process(driver, "chromedriver")
        _stop_process(stub, "e2e-stub")


if __name__ == "__main__":
    raise SystemExit(main())
