# Contributing to Sloppa

Thanks for your interest! This project is a CDP-driven reverse proxy for ChatGPT's web interface, and contributions are welcome.

## Quick Start

```bash
git clone https://github.com/Elephant-Rock-Lab/Sloppa.git
cd Sloppa
pip install -e ".[dev]"
```

## Development Setup

1. **Chrome + ChatGPT**: You need a ChatGPT Plus account and Chrome installed locally.
2. **Run the proxy**: `sloppa` — logs in on first run, starts API server.
3. **Test**: `pytest` (unit tests) or manual `curl` against `localhost:8080`.

## How to Contribute

### Bug Reports

Open an [issue](https://github.com/Elephant-Rock-Lab/Sloppa/issues) with:
- What you expected
- What happened instead
- Steps to reproduce (Chrome version, OS, ChatGPT account type)
- Relevant logs (`--log-level DEBUG`)

### Pull Requests

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Add tests if applicable
5. Ensure `pytest` passes
6. Submit a PR with a clear description of what changed and why

### Code Style

- Python 3.11+, type hints preferred
- Async everywhere (`async/await`, no blocking calls in event loop)
- Docstrings on public functions and classes
- Keep the CDP driver methods pure — business logic belongs in `mcp_server.py` or `api_server.py`

## Architecture

```
src/sloppa/
  __main__.py     CLI entrypoint
  config.py       Configuration from file/env/CLI
  chrome.py       Chrome subprocess lifecycle
  cdp_driver.py   CDP primitives (type, click, stream, API fetch)
  api_server.py   OpenAI-compatible HTTP server
  mcp_server.py   MCP server (tools, resources, prompts)
  service.py      Orchestrator: Chrome → CDP → API
```

## Areas That Need Help

- **Testing**: More comprehensive test coverage (currently relying on live Chrome sessions)
- **Memory endpoint discovery**: `POST /backend-api/memories` returns 405 — the actual write endpoint is unknown
- **Headless support**: Headless Chrome likely triggers anti-bot detection
- **Image/file upload**: CDP-based file upload to conversations and projects
- **Retry logic**: Better recovery from Chrome disconnections and token expiry
- **CI/CD**: GitHub Actions for automated testing

## Code of Conduct

Be respectful. Be constructive. Focus on the code and the problem.
