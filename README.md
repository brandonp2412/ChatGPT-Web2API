# Sloppa

Sloppa is a local ChatGPT bridge and client. The Python backend exposes a REST/MCP API and keeps the browser session on the server. The Flutter app is a custom client that talks to that backend.

## Run locally

Requirements: Python 3.11+, Flutter, and Chrome or Chromium.

Install [Astral uv](https://docs.astral.sh/uv/).

### 1. Start the backend

From the repository root:

```bash
uv sync --extra dev
uv run sloppa
```

On the first run, Sloppa opens Chrome. Sign in to ChatGPT in that browser. The backend is then available at `http://127.0.0.1:8080`.

`uv sync` installs this checkout and its dependencies into a local environment. The package does not need to be published to PyPI.

### 2. Start the Flutter client

In another terminal:

```bash
cd client
flutter pub get
flutter run
```

The client defaults to `http://127.0.0.1:8080`. You can change the bridge URL in the app’s Settings.

## Local client E2E test

The deterministic test backend does not contact ChatGPT:

```bash
cd client
flutter build web --dart-define=SLOPPA_BRIDGE_URL=http://127.0.0.1:18080
cd ..
uv run python scripts/local_webdriver_e2e.py
```

This starts a local fixture API, serves the built Flutter web app, and checks the rendered client through local ChromeDriver.

## Repository layout

- `src/sloppa/` — Python backend and MCP server
- `client/` — Flutter frontend
- `scripts/e2e_stub_backend.py` — deterministic local API fixture
- `tests/` and `client/test/` — automated tests

## License

MIT
