# Design: Auto-Capture Diagnostic + Assisted-Fix Mechanism

**Date:** 2026-06-19
**Status:** Approved (design phase)

## Problem

ChatGPT changes its web UI and backend API over time, silently breaking driver
functions that the unit-test mocks cannot detect. This session alone hit five
such breakages, each requiring a throwaway `probe_*.py` script to diagnose:

| Function | Breakage | How discovered |
|---|---|---|
| `_js_with_data` | Page now defines a global `__D` → SyntaxError | Manual live test |
| `get_models` | Returns raw JSON string, not `list[dict]` | E2E test |
| `create_project` | Nested body now 422s | Step-0 probe |
| `update_project_instructions` | PATCH/PUT now 405 | Step-0 probe |
| `delete_memory` schema | Returns `memory_id`, schema wants `conversation_id` | Integration test |

Every diagnosis required reconstructing the same evidence by hand: the exact
request sent, the live response, the DOM state, the expected-vs-actual shape.
There is no mechanism to capture this at the moment of failure, and no guided
workflow to turn the captured evidence into a fix.

## Goal

A **reactive** mechanism (no monitoring, no background traffic) that:

1. **Detects** when a driver function is broken — at the moment a real call
   fails or returns malformed data in production.
2. **Captures** the exact diagnostic evidence automatically (replacing the
   throwaway probe scripts).
3. **Assists** a human through fixing the function from the captured evidence,
   then **re-verifies** the fix against the live account.

The trigger is the production error path, not a schedule. The fix is proposed
by an AI assist and applied by a human — no silent auto-patching.

## Non-goals

- No runtime fallback/failover (masks breakage; rejected).
- No continuous health monitor (rejected — adds traffic).
- No automatic code changes committed without human review.

## Architecture

```
Production call (e.g. create_project)
        │
        ▼
   [Detector] ── passes ──▶ normal result returned
        │
   fails / malformed
        │
        ▼
   [Capture] ──▶ ~/.sloppa/diagnostics/<func>-<ts>.json
        │            (request, live response, DOM, expected vs actual,
        │             context — all redacted)
        ▼
   normal error returned to caller (capture is non-blocking)
        .
        .  (later, human notices / CI reports / user reports)
        ▼
   [doctor <function>]
        │  reads latest artifact for the function
        ▼
   [Assisted-fix] ──▶ proposes corrected payload/selector/parse from evidence
        │              human reviews each proposal
        ▼
   [Re-verify] ───▶ runs the patched function against live account
        │             pass → done; fail → loop back with new artifact
```

## Components

### 1. Failure detector (the trigger)

A wrapper around each driver method that classifies the result as healthy or
broken. A result is **broken** if any of:

- It returns an explicit error shape (`{"error": ...}`).
- It fails its expected schema (e.g. a method typed `-> list[dict]` returns a
  string, or a required field is absent).
- It raises an unexpected exception (not `RateLimitError`, which is already
  handled by the retry layer).

The detector lives on the **error path of real calls** — it does not initiate
traffic. It is the reactive trigger: breakage in the wild is captured at the
moment it happens.

Implementation: a decorator `@diagnose(function_name, expected_shape)` on each
driver method. On a healthy return, pass through. On a broken return, invoke
the capture layer (non-blocking) and then return the original result/error so
the caller's behavior is unchanged.

### 2. Diagnostic capture (the artifact)

When the detector triggers, dump a structured JSON artifact to
`~/.sloppa/diagnostics/<function>-<timestamp>.json` containing:

- `function`: the driver method name.
- `timestamp`: ISO-8601.
- `request`: the exact JS/fetch expression sent (the `_js`/`_js_with_data`
  template + the data args, **redacted** of tokens/PII).
- `response`: the raw live response — HTTP status, headers, body (truncated),
  or the DOM snapshot for DOM-based methods.
- `expected`: the shape the method promised (from its annotation/schema).
- `actual`: what it got.
- `mismatch`: a human-readable description of the specific failure.
- `context`: page URL, ChatGPT page state, driver internals relevant to triage.

**Redaction:** auth tokens, cookie values, and any user-identifying fields are
replaced with `<redacted>` before writing. (The project already hit PII
sensitivity — commit `57cc094` — so redaction is mandatory, not optional.)

**Volume cap:** keep only the N (default 5) most recent artifacts per function,
deleting older ones, so a repeatedly-broken function can't fill the disk.

Capture is **non-blocking and best-effort**: a capture failure must never mask
or worsen the original error. Capture errors are logged and swallowed.

### 3. Assisted-fix workflow (`doctor` subcommand)

A new `sloppa doctor <function>` subcommand that:

1. Reads the latest diagnostic artifact for `<function>` (or `--all` for every
   function with artifacts).
2. **Prints the evidence** to the console: the captured request, the live
   response, the expected-vs-actual mismatch. This is the same evidence the
   throwaway probe scripts gathered by hand this session — now produced
   automatically and reproducibly.

From there, the **assisted-fix** is an interactive workflow driven by an AI
coding agent (e.g. ZCode) operating on the printed evidence — *not* a bundled
model inside the project. The workflow:

3. The agent **proposes** a fix from the evidence — e.g. a corrected POST body
   shape (flat vs nested), a corrected CSS selector, a corrected JSON-parse
   path, or a corrected output schema. The proposal cites the specific evidence
   it's derived from.
4. The human reviews/edits the proposal.
5. The agent **re-verifies** the proposed fix against the live account by
   running the patched function (in a create-then-cleanup safe way for mutating
   tools, reusing the E2E safety model) via `doctor --verify <function>`.
6. Loops: if re-verify fails, a new artifact is captured and the agent
   re-proposes. If it passes, the human applies the change to the source.

So the project ships two things: the **capture** (deterministic, runs in prod)
and the **doctor command** (prints evidence + runs `--verify`). The
**fix-proposing** is done by whichever AI agent the human points at the
evidence — the project's job is to make the evidence complete and trustworthy,
not to bundle an AI. Every source change is human-applied and human-committed.

## Design decisions (from the brainstorm)

- **Reactive only** — detector on the error path of real calls; no monitoring,
  no scheduled probes, no added traffic.
- **All 15 tools** — detector wraps every driver method; capture is per-function;
  doctor can re-verify any function.
- **Assisted-fix, human-applied** — AI proposes from evidence + re-verifies;
  human reviews and applies. No silent auto-patching.

## Open implementation details (settled during implementation, not design)

- **Exact redaction rules** — a list of fields/patterns (auth header value,
  `accessToken`, `__Secure-` cookies, email-like strings) replaced with
  `<redacted>`. Captured body samples are truncated to a safe size.
- **Schema source for "expected"** — derived from the method's type annotation
  where possible (`-> list[dict]`, `-> dict`), supplemented by an explicit
  expected-shape registry for methods whose contract is richer than the
  annotation (e.g. create_project must return `{id, name, ...}`).
- **Re-verify safety** — reuses the E2E suite's safety primitives
  (snapshot/diff, create-then-cleanup, registration for the cleanup finalizer)
  so doctor never leaves orphaned state on the account.

## Testing

- **Unit:** detector classification (healthy vs each broken class), redaction
  (token/PII stripped), artifact shape, volume-cap eviction. All browser-free.
- **Integration:** a mocked driver returning a broken shape triggers a capture
  artifact with the expected evidence; `doctor` reads it and proposes a fix.
- **E2E (opt-in):** against a live account, deliberately induce a known-broken
  path (e.g. create_project), confirm an artifact is captured, and that
  `doctor create_project` proposes a corrected payload and re-verifies it.

## Risks

- **Detector false-negatives** — a method could return a *plausible but wrong*
  shape (e.g. a list of dicts missing a new field) that passes naive checks.
  Mitigation: schema checks are as specific as the method's real contract.
- **Detector overhead** — wrapping every call adds a classification step.
  Mitigation: classification is cheap (shape check on an in-memory result); the
  expensive capture only runs on failure.
- **Assist proposing a wrong fix** — the AI could misread evidence.
  Mitigation: human reviews every proposal; re-verify catches wrong fixes
  before they're applied to source.
