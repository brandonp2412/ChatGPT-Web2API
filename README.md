# Sloppa

Sloppa is a local, subscription-backed ChatGPT bridge. The Python service drives a persistent Chrome session logged into chatgpt.com and exposes REST and MCP interfaces for programmatic use.

## Run locally

Requirements: Python 3.11+ and Chrome or Chromium.

Install [Astral uv](https://docs.astral.sh/uv/).

From the repository root:

```bash
uv sync --extra dev
uv run sloppa
```

On the first run, Sloppa opens Chrome. Sign in to ChatGPT in that browser. The session is stored in the configured Chrome profile and reused on later starts. The REST API defaults to `http://127.0.0.1:8080`.

`uv sync` installs this checkout and its dependencies into a local environment. The package does not need to be published to PyPI.

## Interfaces

Sloppa exposes an OpenAI-compatible chat-completions endpoint alongside richer ChatGPT conversation/project endpoints and an MCP server.

Common endpoints include:

- `POST /v1/chat/completions`
- `POST /v1/chat/send`
- `GET /v1/conversations`
- `GET /v1/models`
- `GET /v1/projects`
- `GET /health`

Run the MCP server with:

```bash
uv run sloppa-mcp
```

## Verification

Run the backend-only local checks with:

```bash
scripts/verify_local.sh
```

## Repository layout

- `src/sloppa/` — Python backend, browser automation, REST API, and MCP server
- `tests/` — backend automated tests
- `scripts/` — backend diagnostics, live-capture utilities, and operational helpers
- `docs/` — architecture, protocol, deployment, and reverse-engineering notes

## License

MIT
