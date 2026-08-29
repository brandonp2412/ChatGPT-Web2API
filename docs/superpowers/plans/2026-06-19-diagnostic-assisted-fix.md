# Diagnostic Auto-Capture + Assisted-Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reactive mechanism that captures diagnostic evidence when a driver function breaks against the live ChatGPT API, plus a `doctor` subcommand that prints the evidence and re-verifies fixes — so a human + AI agent can repair drift fast.

**Architecture:** A `@diagnose` decorator wraps each `CDPDriver` method, classifying its result as healthy/broken on the error path of real calls. On breakage it writes a redacted JSON artifact under `~/.sloppa/diagnostics/`. A new `sloppa doctor <function>` subcommand prints the latest artifact and (via `--verify`) re-runs the function live. Fix-proposing is done by an external AI agent reading the printed evidence — the project ships capture + doctor, not an AI.

**Tech Stack:** Python 3.11+, aiohttp/websockets (existing), pytest + pytest-asyncio (existing), stdlib `json`/`pathlib`/`re` for capture and redaction.

---

## File Structure

- **Create:** `src/sloppa/diagnostics.py` — the detector (`@diagnose` decorator), artifact capture, redaction, expected-shape registry, volume cap. Pure, no browser dependency.
- **Create:** `src/sloppa/doctor.py` — the `doctor` subcommand logic: read/print artifacts, `--verify` runner.
- **Modify:** `src/sloppa/cdp_driver.py` — apply `@diagnose` to the 15 driver methods.
- **Modify:** `src/sloppa/__main__.py` — register the `doctor` subcommand.
- **Test:** `tests/test_diagnostics.py` — detector, redaction, artifact shape, volume cap (unit).
- **Test:** `tests/test_doctor.py` — artifact reading, evidence printing, verify runner (unit, mocked driver).
- **Test:** `tests/test_e2e_doctor.py` — opt-in live capture + verify round-trip.

---

## Task 1: Diagnostics module — expected-shape registry + classifier

**Files:**
- Create: `src/sloppa/diagnostics.py`
- Test: `tests/test_diagnostics.py`

- [ ] **Step 1: Write the failing test for result classification**

Create `tests/test_diagnostics.py`:

```python
"""Tests for the diagnostic detector + capture."""
import pytest

from sloppa.diagnostics import classify_result, EXPECTED_SHAPES


def test_classify_healthy_list():
    """A list[dict] result with the expected keys is healthy."""
    result = [{"slug": "gpt-5", "title": "GPT-5"}]
    healthy, mismatch = classify_result("get_models", result)
    assert healthy is True
    assert mismatch is None


def test_classify_broken_returns_error_shape():
    """A result that is an {'error': ...} dict is broken."""
    result = {"error": "HTTP 422", "body": "..."}
    healthy, mismatch = classify_result("create_project", result)
    assert healthy is False
    assert "error" in mismatch.lower()


def test_classify_broken_wrong_type():
    """A method promising list[dict] but returning a str is broken (the get_models bug)."""
    result = '{"models": [...]}'  # raw string, not parsed
    healthy, mismatch = classify_result("get_models", result)
    assert healthy is False
    assert "list" in mismatch.lower() or "type" in mismatch.lower()


def test_classify_broken_missing_required_key():
    """A dict result missing a required key is broken."""
    # create_project must return {id, name, ...}; missing id is broken
    result = {"name": "Foo"}  # no id
    healthy, mismatch = classify_result("create_project", result)
    assert healthy is False
    assert "id" in mismatch


def test_expected_shapes_registry_covers_mutating_tools():
    """The registry must define shapes for the tools most likely to drift."""
    for fn in ("create_project", "get_models", "get_conversations", "get_memories"):
        assert fn in EXPECTED_SHAPES, f"{fn} missing from EXPECTED_SHAPES"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/test_diagnostics.py -v`
Expected: FAIL with `ImportError: cannot import name 'classify_result'`

- [ ] **Step 3: Write the minimal implementation**

Create `src/sloppa/diagnostics.py`:

```python
"""Reactive diagnostics: detect broken driver calls + capture evidence.

When ChatGPT changes its API/UI, driver methods silently return wrong shapes.
This module classifies results against an expected-shape registry so breakage
is caught at the moment it happens, then (in Task 2) captures the evidence.
"""

from __future__ import annotations

from typing import Any

# Expected shape per driver method. Each entry is a dict with:
#   kind: "list" | "dict" | "bool" | "any"
#   required_keys: list[str]   (for dict/list-of-dict; each item must have these)
# A method NOT in the registry is classified by kind only (from its annotation
# at decorate time — handled in Task 3); here we register the contracts that
# are richer than "it returned something".
EXPECTED_SHAPES: dict[str, dict] = {
    "get_models": {"kind": "list", "item_required_keys": ["slug", "title"]},
    "get_projects": {"kind": "list", "item_required_keys": ["id", "name"]},
    "get_conversations": {"kind": "list", "item_required_keys": ["id", "title"]},
    "get_conversation": {"kind": "dict", "required_keys": ["id", "messages"]},
    "get_memories": {"kind": "list", "item_required_keys": ["id", "content"]},
    "list_gpts": {"kind": "list", "item_required_keys": ["id", "name"]},
    "get_project_files": {"kind": "list", "item_required_keys": ["id", "name"]},
    "create_project": {"kind": "dict", "required_keys": ["id", "name"]},
    "update_project_instructions": {"kind": "dict", "required_keys": ["success", "project_id"]},
    "archive_conversation": {"kind": "dict", "required_keys": ["success", "conversation_id"]},
    "delete_conversation": {"kind": "bool"},
    "delete_memory": {"kind": "bool"},
    "create_memory": {"kind": "dict", "required_keys": ["content"]},
}


def classify_result(function_name: str, result: Any) -> tuple[bool, str | None]:
    """Classify a driver method's return as healthy or broken.

    Returns (healthy, mismatch). healthy is True when the result matches the
    method's registered shape; mismatch is a short human description of why not.

    Broken cases:
      - result is a dict containing an "error" key (explicit API error)
      - result type doesn't match the registered kind
      - a dict result is missing a required key
      - a list result's items are missing item_required_keys
    """
    spec = EXPECTED_SHAPES.get(function_name, {"kind": "any"})

    # Explicit error shape — every method's fetch wrappers return this on !ok.
    if isinstance(result, dict) and "error" in result:
        return False, f"returned error shape: {result.get('error', '?')}"

    kind = spec.get("kind", "any")
    if kind == "any":
        return True, None
    if kind == "bool":
        if not isinstance(result, bool):
            return False, f"expected bool, got {type(result).__name__}"
        return True, None
    if kind == "list":
        if not isinstance(result, list):
            return False, f"expected list, got {type(result).__name__}"
        req = spec.get("item_required_keys", [])
        for i, item in enumerate(result[:3]):  # check first few items
            if not isinstance(item, dict):
                return False, f"list item {i} is {type(item).__name__}, not dict"
            missing = [k for k in req if k not in item]
            if missing:
                return False, f"list item {i} missing keys: {missing}"
        return True, None
    if kind == "dict":
        if not isinstance(result, dict):
            return False, f"expected dict, got {type(result).__name__}"
        missing = [k for k in spec.get("required_keys", []) if k not in result]
        if missing:
            return False, f"missing required keys: {missing}"
        return True, None
    return True, None
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pytest tests/test_diagnostics.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add src/sloppa/diagnostics.py tests/test_diagnostics.py
git commit -m "feat(diagnostics): add result classifier + expected-shape registry"
```

---

## Task 2: Artifact capture + redaction + volume cap

**Files:**
- Modify: `src/sloppa/diagnostics.py`
- Test: `tests/test_diagnostics.py` (append)

- [ ] **Step 1: Write the failing tests for redaction + capture**

Append to `tests/test_diagnostics.py`:

```python
import json
from pathlib import Path

from sloppa.diagnostics import redact, capture_artifact, DiagnosticsDir


def test_redact_strips_auth_tokens():
    """Auth tokens, cookie values, and emails are replaced with <redacted>."""
    s = redact({
        "headers": {"Authorization": "Bearer eyJabc123.def"},
        "cookie": "__Secure-next-auth.session-token=longvalue",
        "email": "user@example.com",
        "url": "https://chatgpt.com/backend-api/conversation/abc-123",
    })
    assert "eyJabc123" not in json.dumps(s)
    assert "<redacted>" in json.dumps(s)
    # conversation IDs in URLs are NOT PII — keep them
    assert "abc-123" in s["url"]


def test_redact_truncates_long_bodies():
    """Captured response bodies are truncated to a safe size."""
    s = redact({"body": "x" * 10000})
    assert len(s["body"]) <= 2000


def test_capture_artifact_writes_redacted_json(tmp_path):
    """capture_artifact writes a redacted JSON file named <func>-<ts>.json."""
    diag = DiagnosticsDir(base=tmp_path)
    path = diag.capture(
        function="create_project",
        request={"expression": "fetch(...)", "data": {"token": "secret"}},
        response={"status": 422, "body": "validation error"},
        expected={"kind": "dict", "required_keys": ["id", "name"]},
        actual={"error": "HTTP 422"},
        mismatch="returned error shape: HTTP 422",
    )
    assert path.exists()
    data = json.loads(path.read_text())
    assert data["function"] == "create_project"
    assert data["mismatch"] == "returned error shape: HTTP 422"
    # redaction applied
    assert data["request"]["data"]["token"] == "<redacted>"


def test_capture_volume_cap_keeps_newest(tmp_path):
    """Only the N most recent artifacts per function are kept."""
    diag = DiagnosticsDir(base=tmp_path, max_per_function=3)
    for i in range(5):
        diag.capture(
            function="get_models", request={}, response={}, expected={},
            actual={}, mismatch=f"m{i}",
        )
    files = sorted(tmp_path.glob("get_models-*.json"))
    assert len(files) == 3
    kept = [json.loads(f.read_text())["mismatch"] for f in files]
    # newest 3 (m2, m3, m4) kept; m0, m1 evicted
    assert "m2" in kept and "m1" not in kept
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_diagnostics.py -v`
Expected: FAIL with `ImportError: cannot import name 'redact'`

- [ ] **Step 3: Write the implementation**

Append to `src/sloppa/diagnostics.py`:

```python
import json
import re
import time
from pathlib import Path

# Patterns treated as secrets/PII and redacted whole.
_REDACT_VALUE_PATTERNS = [
    re.compile(r"eyJ[A-Za-z0-9_\.\-]{20,}"),  # JWT-looking tokens
    re.compile(r"__Secure-[A-Za-z0-9_\.\-]+=[A-Za-z0-9_\.\-]{20,}"),  # secure cookies
    re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"),  # emails
]
_REDACT_KEY_HINTS = ("token", "authorization", "cookie", "password", "secret", "email")
_MAX_BODY_CHARS = 2000


def _redact_string(s: str) -> str:
    for pat in _REDACT_VALUE_PATTERNS:
        s = pat.sub("<redacted>", s)
    return s


def redact(obj):
    """Recursively redact secrets/PII from a JSON-serializable structure.

    Replaces JWTs, secure-cookie values, and emails anywhere in strings; blanks
    values whose key hints at being a secret; truncates long string values.
    """
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if any(hint in k.lower() for hint in _REDACT_KEY_HINTS):
                out[k] = "<redacted>"
            else:
                out[k] = redact(v)
        return out
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    if isinstance(obj, str):
        truncated = obj if len(obj) <= _MAX_BODY_CHARS else obj[:_MAX_BODY_CHARS] + "...<truncated>"
        return _redact_string(truncated)
    return obj


class DiagnosticsDir:
    """Writes + reads diagnostic artifacts under a base directory."""

    def __init__(self, base: Path | None = None, max_per_function: int = 5) -> None:
        self.base = Path(base) if base else Path.home() / ".sloppa" / "diagnostics"
        self.base.mkdir(parents=True, exist_ok=True)
        self.max_per_function = max_per_function

    def capture(self, *, function, request, response, expected, actual, mismatch) -> Path:
        """Write a redacted artifact and enforce the per-function volume cap."""
        ts = time.strftime("%Y%m%d-%H%M%S")
        path = self.base / f"{function}-{ts}.json"
        payload = redact({
            "function": function,
            "timestamp": ts,
            "request": request,
            "response": response,
            "expected": expected,
            "actual": actual,
            "mismatch": mismatch,
        })
        path.write_text(json.dumps(payload, indent=2, default=str))
        self._enforce_cap(function)
        return path

    def _enforce_cap(self, function: str) -> None:
        files = sorted(self.base.glob(f"{function}-*.json"))
        excess = len(files) - self.max_per_function
        for f in files[:max(0, excess)]:
            try:
                f.unlink()
            except OSError:
                pass

    def latest(self, function: str) -> Path | None:
        files = sorted(self.base.glob(f"{function}-*.json"))
        return files[-1] if files else None
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_diagnostics.py -v`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add src/sloppa/diagnostics.py tests/test_diagnostics.py
git commit -m "feat(diagnostics): add artifact capture with redaction + volume cap"
```

---

## Task 3: The `@diagnose` decorator — wire detection into driver methods

**Files:**
- Modify: `src/sloppa/diagnostics.py`
- Modify: `src/sloppa/cdp_driver.py` (apply decorator to 15 methods)
- Test: `tests/test_diagnostics.py` (append)

- [ ] **Step 1: Write the failing test for the decorator**

Append to `tests/test_diagnostics.py`:

```python
import asyncio
from unittest.mock import MagicMock, AsyncMock

from sloppa.diagnostics import diagnose, set_capture_enabled


def test_diagnose_decorator_passes_through_healthy(monkeypatch, tmp_path):
    """A healthy result is returned unchanged; no artifact written."""
    monkeypatch.setattr("sloppa.diagnostics._DIAG_DIR",
                        __import__("sloppa.diagnostics", fromlist=["DiagnosticsDir"]).DiagnosticsDir(base=tmp_path))

    class Stub:
        @diagnose("get_models")
        async def get_models(self_inner):
            return [{"slug": "a", "title": "A"}]

    result = asyncio.run(Stub().get_models())
    assert result == [{"slug": "a", "title": "A"}]
    assert not list(tmp_path.glob("*.json"))  # no artifact


def test_diagnose_decorator_captures_on_broken(monkeypatch, tmp_path):
    """A broken result is still returned, but an artifact is captured."""
    from sloppa.diagnostics import DiagnosticsDir
    monkeypatch.setattr("sloppa.diagnostics._DIAG_DIR", DiagnosticsDir(base=tmp_path))

    class Stub:
        async def _js(self_inner, expr, timeout=15):
            # simulate the JS that would have run
            return '{"error":"HTTP 422"}'

        @diagnose("create_project", capture_js=lambda self_inner: ("fetch expr", {"token": "x"}))
        async def create_project(self_inner, name="x"):
            return {"error": "HTTP 422", "body": "bad"}

    result = asyncio.run(Stub().create_project(name="Foo"))
    assert result == {"error": "HTTP 422", "body": "bad"}  # caller sees original
    files = list(tmp_path.glob("create_project-*.json"))
    assert len(files) == 1
    art = json.loads(files[0].read_text())
    assert art["function"] == "create_project"
    assert art["request"]["expression"] == "fetch expr"


def test_diagnose_capture_is_disabled_by_default(monkeypatch, tmp_path):
    """Capture is OFF unless enabled (avoid surprising disk writes in prod)."""
    from sloppa.diagnostics import DiagnosticsDir
    monkeypatch.setattr("sloppa.diagnostics._DIAG_DIR", DiagnosticsDir(base=tmp_path))
    set_capture_enabled(False)

    class Stub:
        @diagnose("get_models")
        async def get_models(self_inner):
            return "wrong type"

    asyncio.run(Stub().get_models())
    assert not list(tmp_path.glob("*.json"))  # disabled → no capture
    set_capture_enabled(True)  # restore for other tests
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_diagnostics.py -v`
Expected: FAIL with `ImportError: cannot import name 'diagnose'`

- [ ] **Step 3: Write the decorator implementation**

Append to `src/sloppa/diagnostics.py`:

```python
import asyncio
import functools
import logging

logger = logging.getLogger(__name__)

# Single shared diagnostics directory. Capture only runs when enabled (default
# off) so a fresh checkout never surprises the user with disk writes. Enabled
# by the server at startup (Task 5) or by the doctor command.
_DIAG_DIR = DiagnosticsDir()
_capture_enabled = False


def set_capture_enabled(enabled: bool) -> None:
    global _capture_enabled
    _capture_enabled = enabled


def _safe_classify_and_capture(function_name, result, request_provider):
    """Classify result; if broken and capture enabled, write an artifact.

    Best-effort: never raises. A capture failure is logged and swallowed so it
    can never mask or worsen the original error.
    """
    try:
        healthy, mismatch = classify_result(function_name, result)
        if healthy:
            return
        if not _capture_enabled:
            return
        request = {}
        try:
            if request_provider:
                request = request_provider()
        except Exception:
            request = {"note": "request capture failed"}
        _DIAG_DIR.capture(
            function=function_name,
            request=request,
            response={"result": result},
            expected=EXPECTED_SHAPES.get(function_name, {"kind": "any"}),
            actual=result,
            mismatch=mismatch or "unknown",
        )
    except Exception:
        logger.warning("diagnostic capture failed", exc_info=True)


def diagnose(function_name: str, capture_js=None):
    """Decorator: classify a driver method's result + capture on breakage.

    Args:
        function_name: the name used in artifacts and the shape registry.
        capture_js: optional callable(self) -> (expression_str, data_dict) that
            returns the JS request that was sent, for inclusion in the artifact.
            None if the method's request isn't reconstructable cheaply.

    The wrapped method's return value / exception is always passed through
    unchanged — detection is a side channel, never a behavior change.
    """
    def decorator(fn):
        if asyncio.iscoroutinefunction(fn):
            @functools.wraps(fn)
            async def async_wrapper(self, *args, **kwargs):
                result = await fn(self, *args, **kwargs)
                _safe_classify_and_capture(
                    function_name, result,
                    (lambda: capture_js(self)) if capture_js else None,
                )
                return result
            return async_wrapper
        @functools.wraps(fn)
        def sync_wrapper(self, *args, **kwargs):
            result = fn(self, *args, **kwargs)
            _safe_classify_and_capture(
                function_name, result,
                (lambda: capture_js(self)) if capture_js else None,
            )
            return result
        return sync_wrapper
    return decorator
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_diagnostics.py -v`
Expected: PASS (12 tests)

- [ ] **Step 5: Apply `@diagnose` to the 15 driver methods**

In `src/sloppa/cdp_driver.py`, add the import and decorate each method. Example for the two methods with JS-capture:

```python
from .diagnostics import diagnose
```

For `get_models` (cdp_driver.py:653):
```python
    @diagnose("get_models")
    async def get_models(self) -> list[dict]:
```

For `create_project` (cdp_driver.py:794):
```python
    @diagnose(
        "create_project",
        capture_js=lambda self: (
            "POST /backend-api/gizmos", {"name": "<arg>", "memory_scope": "<arg>"}
        ),
    )
    async def create_project(self, name, instructions="", memory_scope="project_v2") -> dict:
```

Apply `@diagnose("<name>")` (no capture_js for reads) to: `get_projects`, `get_conversations`, `get_conversation`, `get_memories`, `list_gpts`, `get_project_files`, `update_project_instructions`, `archive_conversation`, `create_memory`. For `delete_conversation` and `delete_memory` (return bool), use `@diagnose("<name>")`.

- [ ] **Step 6: Run the full unit suite to confirm no regressions**

Run: `pytest -q`
Expected: PASS (all existing + 12 new). Decorator is inert when capture is off (default).

- [ ] **Step 7: Commit**

```bash
git add src/sloppa/diagnostics.py src/sloppa/cdp_driver.py tests/test_diagnostics.py
git commit -m "feat(diagnostics): add @diagnose decorator; apply to driver methods"
```

---

## Task 4: Enable capture at server startup (opt-in via env)

**Files:**
- Modify: `src/sloppa/diagnostics.py`
- Modify: `src/sloppa/service.py`
- Test: `tests/test_diagnostics.py` (append)

- [ ] **Step 1: Write the failing test for env-gated enablement**

Append to `tests/test_diagnostics.py`:

```python
def test_capture_enabled_by_env(monkeypatch):
    """SLOPPA_DIAGNOSE=1 enables capture at startup."""
    import sloppa.diagnostics as dmod
    monkeypatch.setenv("SLOPPA_DIAGNOSE", "1")
    dmod.apply_env_enablement()
    assert dmod._capture_enabled is True

    monkeypatch.delenv("SLOPPA_DIAGNOSE", raising=False)
    dmod.apply_env_enablement()
    assert dmod._capture_enabled is False
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/test_diagnostics.py::test_capture_enabled_by_env -v`
Expected: FAIL with `AttributeError: module ... has no attribute 'apply_env_enablement'`

- [ ] **Step 3: Implement env-gated enablement**

Append to `src/sloppa/diagnostics.py`:

```python
import os


def apply_env_enablement() -> None:
    """Enable capture when SLOPPA_DIAGNOSE is truthy (called at server startup)."""
    global _capture_enabled
    _capture_enabled = os.environ.get("SLOPPA_DIAGNOSE", "").lower() in ("1", "true", "yes")
```

In `src/sloppa/service.py`, inside `Service.start()` (before connecting the driver), add:

```python
from .diagnostics import apply_env_enablement
apply_env_enablement()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pytest tests/test_diagnostics.py -v`
Expected: PASS (13 tests)

- [ ] **Step 5: Commit**

```bash
git add src/sloppa/diagnostics.py src/sloppa/service.py tests/test_diagnostics.py
git commit -m "feat(diagnostics): enable capture at startup via SLOPPA_DIAGNOSE=1"
```

---

## Task 5: The `doctor` subcommand — print evidence

**Files:**
- Create: `src/sloppa/doctor.py`
- Modify: `src/sloppa/__main__.py`
- Test: `tests/test_doctor.py`

- [ ] **Step 1: Write the failing test for evidence printing**

Create `tests/test_doctor.py`:

```python
"""Tests for the doctor subcommand: artifact reading + evidence printing."""
import json
from pathlib import Path

import pytest

from sloppa.doctor import print_evidence, list_functions_with_artifacts


def test_print_evidence_outputs_the_artifact(capsys, tmp_path):
    """print_evidence reads an artifact and prints its key fields."""
    art = tmp_path / "create_project-20260619-120000.json"
    art.write_text(json.dumps({
        "function": "create_project",
        "timestamp": "20260619-120000",
        "request": {"expression": "POST /backend-api/gizmos", "data": {"name": "Foo"}},
        "response": {"result": {"error": "HTTP 422", "body": "validation error"}},
        "expected": {"kind": "dict", "required_keys": ["id", "name"]},
        "actual": {"error": "HTTP 422"},
        "mismatch": "returned error shape: HTTP 422",
    }))
    print_evidence(art)
    out = capsys.readouterr().out
    assert "create_project" in out
    assert "HTTP 422" in out
    assert "POST /backend-api/gizmos" in out
    assert "id" in out  # expected keys shown


def test_list_functions_with_artifacts(tmp_path):
    """list_functions_with_artifacts returns distinct function names present."""
    for fn in ("get_models", "get_models", "create_project"):
        (tmp_path / f"{fn}-20260619-120000.json").write_text("{}")
    fns = list_functions_with_artifacts(tmp_path)
    assert set(fns) == {"get_models", "create_project"}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/test_doctor.py -v`
Expected: FAIL with `ImportError: cannot import name 'print_evidence'`

- [ ] **Step 3: Write the doctor module**

Create `src/sloppa/doctor.py`:

```python
"""The `doctor` subcommand: print diagnostic evidence + re-verify fixes.

doctor is the human-facing surface for the assisted-fix workflow. It reads the
latest artifact for a broken function and prints the captured evidence (request,
live response, expected-vs-actual mismatch) — the same information the throwaway
probe scripts gathered by hand. An external AI agent reads this evidence and
proposes a fix; `doctor --verify` then re-runs the function live to confirm.
"""

from __future__ import annotations

import json
from pathlib import Path


def list_functions_with_artifacts(base: Path) -> list[str]:
    """Return distinct function names that have at least one artifact."""
    return sorted({p.name.split("-")[0] for p in Path(base).glob("*.json")})


def print_evidence(artifact_path: Path) -> None:
    """Print the captured diagnostic evidence for human / AI-agent reading."""
    data = json.loads(Path(artifact_path).read_text())
    print("=" * 60)
    print(f"FUNCTION:   {data.get('function', '?')}")
    print(f"TIMESTAMP:  {data.get('timestamp', '?')}")
    print(f"MISMATCH:   {data.get('mismatch', '?')}")
    print("=" * 60)
    print("\n--- REQUEST (what was sent) ---")
    print(json.dumps(data.get("request", {}), indent=2)[:2000])
    print("\n--- RESPONSE (what came back) ---")
    print(json.dumps(data.get("response", {}), indent=2)[:2000])
    print("\n--- EXPECTED shape ---")
    print(json.dumps(data.get("expected", {}), indent=2))
    print("\n--- ACTUAL ---")
    print(json.dumps(data.get("actual", {}), indent=2)[:2000])
    print("\nNext: an AI agent reads the above and proposes a corrected "
          "payload/selector/parse. Run `doctor --verify <function>` to test it.")


def run_doctor(args) -> None:
    """Entry point for the `doctor` subcommand."""
    from .diagnostics import _DIAG_DIR
    base = _DIAG_DIR.base

    if getattr(args, "list", False):
        fns = list_functions_with_artifacts(base)
        if not fns:
            print("No diagnostic artifacts found. Set SLOPPA_DIAGNOSE=1 and trigger "
                  "a breakage to capture one.")
            return
        print("Functions with captured artifacts:")
        for fn in fns:
            print(f"  {fn}")
        return

    if getattr(args, "verify", None):
        from .doctor_verify import verify_function
        verify_function(args.verify)
        return

    function = getattr(args, "function", None)
    if not function:
        print("Usage: sloppa doctor <function> | --list | --verify <function>")
        return

    latest = _DIAG_DIR.latest(function)
    if latest is None:
        print(f"No artifact for '{function}'. Capture one by enabling "
              "SLOPPA_DIAGNOSE=1 and triggering the breakage.")
        return
    print_evidence(latest)
```

- [ ] **Step 4: Register the subcommand in `__main__.py`**

In `src/sloppa/__main__.py`, change the subcommands set and add the parser (around line 128-142):

```python
    subcommands = {"start", "inject-cookies", "doctor"}
```
and inside `if has_subcommand:`:
```python
        doctor_parser = subparsers.add_parser("doctor", help="Diagnose a broken function from captured evidence")
        doctor_parser.add_argument("function", nargs="?", help="Function to diagnose")
        doctor_parser.add_argument("--list", action="store_true", help="List functions with artifacts")
        doctor_parser.add_argument("--verify", metavar="FUNCTION", help="Re-run a function live to verify a fix")
```
and in the command dispatch:
```python
    elif command == "doctor":
        from .doctor import run_doctor
        run_doctor(args)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pytest tests/test_doctor.py -v`
Expected: PASS (2 tests). Also run `pytest -q` to confirm the new subcommand wiring doesn't break the suite.

- [ ] **Step 6: Commit**

```bash
git add src/sloppa/doctor.py src/sloppa/__main__.py tests/test_doctor.py
git commit -m "feat(doctor): add doctor subcommand to print diagnostic evidence"
```

---

## Task 6: `doctor --verify` — re-run a function live to confirm a fix

**Files:**
- Create: `src/sloppa/doctor_verify.py`
- Test: `tests/test_doctor.py` (append)

- [ ] **Step 1: Write the failing test for verify**

Append to `tests/test_doctor.py`:

```python
import asyncio
from unittest.mock import AsyncMock, MagicMock

from sloppa import doctor_verify


def test_verify_runs_function_and_reports_pass(monkeypatch, capsys):
    """verify_function runs the live function and reports PASS when healthy."""
    driver = MagicMock()
    driver.get_models = AsyncMock(return_value=[{"slug": "gpt-5", "title": "GPT-5"}])
    monkeypatch.setattr(doctor_verify, "_connect_driver", lambda: driver)

    asyncio.run(doctor_verify.verify_function("get_models"))
    out = capsys.readouterr().out
    assert "PASS" in out


def test_verify_reports_fail_on_broken(monkeypatch, capsys):
    """verify_function reports FAIL when the function is still broken."""
    driver = MagicMock()
    driver.create_project = AsyncMock(return_value={"error": "HTTP 422"})
    monkeypatch.setattr(doctor_verify, "_connect_driver", lambda: driver)

    asyncio.run(doctor_verify.verify_function("create_project"))
    out = capsys.readouterr().out
    assert "FAIL" in out
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/test_doctor.py -v`
Expected: FAIL with `ImportError: cannot import name 'doctor_verify'`

- [ ] **Step 3: Write the verify module**

Create `src/sloppa/doctor_verify.py`:

```python
"""`doctor --verify <function>`: re-run a function live to confirm a fix.

After an AI agent proposes a corrected payload/selector/parse (from the evidence
`doctor` printed), verify runs the patched function against the live account and
reports PASS/FAIL using the same classifier as detection. For mutating tools,
verify uses the create-then-cleanup safety pattern (reused from the E2E suite).
"""

from __future__ import annotations

import asyncio
import sys

from .diagnostics import classify_result
from .cdp_driver import CDPDriver


def _connect_driver() -> CDPDriver:
    """Connect a driver to a running Chrome (CDP 9222). Raises if unavailable."""
    driver = CDPDriver(cdp_port=9222)
    asyncio.get_event_loop().run_until_complete(driver.connect())
    return driver


# Minimal safe invocations per function. Reads take no args; mutating tools use
# throwaway values and clean up afterward. Only the most-likely-to-drift
# functions are wired for verify; others print a pointer to the E2E suite.
_VERIFY_SAFE = {
    "get_models": lambda d: d.get_models(),
    "get_projects": lambda d: d.get_projects(),
    "get_conversations": lambda d: d.get_conversations(limit=1),
    "get_memories": lambda d: d.get_memories(),
    "list_gpts": lambda d: d.list_gpts(),
}


async def _verify_async(function: str) -> int:
    driver = _connect_driver()
    try:
        runner = _VERIFY_SAFE.get(function)
        if runner is None:
            print(f"'{function}' has no safe verify runner. For mutating tools, "
                  "use the E2E suite (tests/test_e2e_*.py) to verify a fix.")
            return 2
        result = await runner(driver)
        healthy, mismatch = classify_result(function, result)
        if healthy:
            print(f"PASS: {function} returned a healthy shape.")
            return 0
        print(f"FAIL: {function} still broken — {mismatch}")
        print(f"Actual: {result!r:.500}")
        return 1
    finally:
        await driver.close()


def verify_function(function: str) -> int:
    """Entry point. Returns process exit code (0=pass, 1=fail, 2=no-runner)."""
    code = asyncio.run(_verify_async(function))
    sys.exit(code)
```

Update `doctor.py`'s import in `run_doctor` (it already references `doctor_verify.verify_function` — ensure the module exists).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_doctor.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/sloppa/doctor_verify.py tests/test_doctor.py
git commit -m "feat(doctor): add --verify to re-run a function live"
```

---

## Task 7: E2E — capture triggers on real breakage + doctor reads it

**Files:**
- Create: `tests/test_e2e_doctor.py`

- [ ] **Step 1: Write the opt-in E2E test**

Create `tests/test_e2e_doctor.py`:

```python
"""E2E: a real broken path triggers capture, and doctor reads the artifact.

Uses create_project (known-broken against the live API) as the trigger: with
SLOPPA_DIAGNOSE=1, calling it captures an artifact; doctor then prints the evidence.

Run with: SLOPPA_E2E_RUN=1 pytest tests/test_e2e_doctor.py -m e2e -v
"""
import json
import os

import pytest

import sloppa.diagnostics as dmod
from sloppa.cdp_driver import CDPDriver

pytestmark = pytest.mark.e2e


async def test_broken_function_triggers_capture(e2e_driver: CDPDriver, tmp_path, monkeypatch):
    """create_project (broken live) writes a diagnostic artifact when enabled."""
    # Point diagnostics at a temp dir + enable capture for this test
    monkeypatch.setattr(dmod, "_DIAG_DIR", dmod.DiagnosticsDir(base=tmp_path))
    monkeypatch.setattr(dmod, "_capture_enabled", True)

    # create_project is known-broken (422); calling it should capture an artifact
    result = await e2e_driver.create_project(name="SLOPPA-DOCTOR-PROBE", instructions="")
    assert isinstance(result, dict) and "error" in result  # confirms it's broken

    files = list(tmp_path.glob("create_project-*.json"))
    assert len(files) == 1, "expected a capture artifact for the broken call"
    art = json.loads(files[0].read_text())
    assert art["function"] == "create_project"
    assert "422" in str(art["actual"]) or "error" in str(art["actual"]).lower()
    # redaction sanity: no raw auth token leaked into the artifact
    assert "Bearer eyJ" not in files[0].read_text()


async def test_doctor_prints_evidence_for_broken_function(e2e_driver, tmp_path, monkeypatch, capsys):
    """After capture, doctor prints the evidence a fix-agent would read."""
    monkeypatch.setattr(dmod, "_DIAG_DIR", dmod.DiagnosticsDir(base=tmp_path))
    monkeypatch.setattr(dmod, "_capture_enabled", True)
    await e2e_driver.create_project(name="SLOPPA-DOCTOR-PROBE2", instructions="")

    from sloppa.doctor import print_evidence
    art = sorted(tmp_path.glob("create_project-*.json"))[-1]
    print_evidence(art)
    out = capsys.readouterr().out
    assert "create_project" in out
    assert "MISMATCH" in out
```

- [ ] **Step 2: Run the suite default to confirm it's deselected**

Run: `pytest tests/test_e2e_doctor.py -q`
Expected: "no tests ran" (deselected; e2e marker excluded by default).

- [ ] **Step 3: Run it live (opt-in, paced)**

Run: `SLOPPA_E2E_RUN=1 pytest tests/test_e2e_doctor.py -m e2e -v`
Expected: PASS (2 tests). This proves the end-to-end reactive loop: real breakage → captured artifact → doctor prints it.

- [ ] **Step 4: Commit**

```bash
git add tests/test_e2e_doctor.py
git commit -m "test(e2e): verify reactive capture triggers + doctor reads evidence"
```

---

## Task 8: Docs + CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `docs/api-reference.md`
- Modify: `CHANGELOG.md`
- Modify: `.env.example`

- [ ] **Step 1: Add a "Troubleshooting Drift" section to README**

Add after the "Rate Limits & Agent Retry" section:

```markdown
### 🩺 Troubleshooting API/UI Drift

ChatGPT changes its web API over time, which can silently break driver functions
(the unit-test mocks can't detect this). Sloppa ships a **reactive
diagnostic** that captures evidence at the moment a function breaks, plus a
`doctor` command that prints it for fast repair.

**Enable capture** (off by default) so breakage in the wild is recorded:

```bash
SLOPPA_DIAGNOSE=1 sloppa start
```

When a function breaks, an artifact is written to
`~/.sloppa/diagnostics/<function>-<timestamp>.json` with the exact
request, live response, expected-vs-actual mismatch (redacted of secrets).

**Diagnose + verify a fix:**

```bash
sloppa doctor --list                  # which functions have artifacts?
sloppa doctor create_project          # print the captured evidence
sloppa doctor --verify get_models     # re-run a function live to test a fix
```

`doctor` prints the evidence an AI coding agent (or you) reads to propose the
corrected payload/selector/parse; `--verify` confirms the fix against the live
account before you commit it. No AI is bundled — the project captures
deterministic evidence; the fix is human-applied.
```

- [ ] **Step 2: Add `SLOPPA_DIAGNOSE` to `.env.example`**

```bash
# Reactive diagnostics: capture evidence when a driver function breaks (off by default).
# Artifacts go to ~/.sloppa/diagnostics/. See README "Troubleshooting Drift".
# SLOPPA_DIAGNOSE=1
```

- [ ] **Step 3: Add to CHANGELOG `[Unreleased]` → Added**

```markdown
- **Reactive drift diagnostics + `doctor` command.** When ChatGPT changes its API/UI and a driver function returns a broken shape, a `@diagnose` decorator captures a redacted artifact (request, live response, expected-vs-actual mismatch) under `~/.sloppa/diagnostics/`. The new `sloppa doctor <function>` command prints the evidence for fast repair, and `doctor --verify <function>` re-runs a function live to confirm a fix. Enabled via `SLOPPA_DIAGNOSE=1` (off by default). Replaces the throwaway probe scripts used during this session's debugging.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/api-reference.md CHANGELOG.md .env.example
git commit -m "docs: add troubleshooting-drift section + doctor command docs"
```

---

## Self-Review (run after writing the plan)

**Spec coverage:**
- ✅ Failure detector (trigger) → Task 1 (classifier) + Task 3 (`@diagnose` decorator on error path).
- ✅ Diagnostic capture (artifact + redaction + volume cap) → Task 2.
- ✅ Assisted-fix workflow (doctor prints evidence, verify re-runs) → Tasks 5–6.
- ✅ All 15 tools → Task 3 Step 5 applies `@diagnose` to all driver methods.
- ✅ Reactive only, no monitoring → detection is on the error path of real calls; capture off by default (Task 3 + Task 4 opt-in env).
- ✅ Redaction → Task 2 (`redact()` + tests).
- ✅ Volume cap → Task 2 (`DiagnosticsDir._enforce_cap` + test).
- ✅ Testing: unit (Tasks 1–6), E2E (Task 7).

**Placeholder scan:** None — every step has concrete code or commands.

**Type/name consistency:** `classify_result(function_name, result)`, `redact(obj)`, `DiagnosticsDir.capture(...)`, `diagnose(function_name, capture_js=)`, `print_evidence(path)`, `verify_function(function)` — consistent across tasks. `set_capture_enabled` / `apply_env_enablement` / `_capture_enabled` / `_DIAG_DIR` consistent.

**Scope:** Single focused mechanism; one plan, working software at each task boundary.
