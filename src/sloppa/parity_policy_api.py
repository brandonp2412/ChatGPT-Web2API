"""HTTP policy boundary for sensitive ChatGPT parity responses."""

from __future__ import annotations

from aiohttp import web

from .parity_secure_api import SecureParityAPIServer


class PolicyParityAPIServer(SecureParityAPIServer):
    """Final API server with explicit no-store and defensive response headers."""

    def __init__(self, config, driver, breakers=None) -> None:
        super().__init__(config, driver, breakers=breakers)
        self.app.on_response_prepare.append(_prepare_sensitive_response)


async def _prepare_sensitive_response(
    request: web.Request,
    response: web.StreamResponse,
) -> None:
    """Apply policy before aiohttp commits headers, including SSE streams."""
    path = request.path
    if path.startswith("/v1/") or path in {"/chat/completions", "/v1/chat/completions"}:
        # The native Flutter client deliberately maintains its own encrypted
        # cache. Intermediary/browser caches must never persist account chat,
        # search results, files, voice negotiation data, or bearer-auth output.
        response.headers["Cache-Control"] = "no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"

        # Do not let an upstream reverse proxy transform/buffer rich streams.
        if response.content_type == "text/event-stream":
            response.headers["X-Accel-Buffering"] = "no"
