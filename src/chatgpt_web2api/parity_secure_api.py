"""Security and client-view boundary for the unified ChatGPT parity API."""

from __future__ import annotations

import asyncio
import urllib.parse
from typing import Any

import aiohttp
from aiohttp import web

from .cdp_driver import AuthExpiredError
from .parity_branch import BranchController
from .parity_browser import ParityBrowserError
from .parity_live_api import LiveParityAPIServer
from .parity_projects import ProjectController
from .parity_view import normalize_client_conversation

# Asset URLs are produced by ChatGPT's authenticated file-resolution endpoint,
# but the bridge still treats the returned URL as untrusted before making a
# server-side request. Keep generic cloud-storage domains out of this list: an
# attacker can own an arbitrary Azure/S3 bucket, whereas these suffixes are
# specific to OpenAI/ChatGPT plus the known DALL-E Azure account.
_ALLOWED_ASSET_HOST_SUFFIXES = (
    "oaiusercontent.com",
    "oaistatic.com",
    "chatgpt.com",
    "openai.com",
)
_ALLOWED_ASSET_HOST_EXACT = {
    "oaidalleapiprodscus.blob.core.windows.net",
}


class SecureParityAPIServer(LiveParityAPIServer):
    """Final service class: current parity, safe tree view and SSRF guard."""

    def __init__(self, config, driver, breakers=None) -> None:
        self._branch_controller = BranchController(driver)
        self._project_controller = ProjectController(driver)
        super().__init__(config, driver, breakers=breakers)
        self.app.router.add_post(
            "/v1/conversations/{conversation_id}/branch/select",
            self._handle_branch_select,
        )
        self.app.router.add_get(
            "/v1/projects/{project_id}/conversations",
            self._handle_project_conversations,
        )
        self.app.router.add_get(
            "/v1/projects/{project_id}/files/{file_id}/download",
            self._handle_project_file_download,
        )

    async def _handle_branch_select(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            target_node_id = str(body.get("target_node_id") or "").strip()
            if not target_node_id:
                return self._bad_request("target_node_id is required")
            conversation_id = request.match_info["conversation_id"]
            async with self._mutation_guard():
                result = await self._branch_controller.select_node(
                    conversation_id,
                    target_node_id,
                )
            snapshot = await self._fetch_snapshot(conversation_id)
            return web.json_response(
                {
                    "object": "branch.selection",
                    "data": result,
                    "conversation": snapshot,
                }
            )
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_project_conversations(
        self, request: web.Request
    ) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            data = await self._project_controller.list_conversations(
                request.match_info["project_id"],
                cursor=request.query.get("cursor", "0"),
            )
            return web.json_response({"object": "list", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_project_file_download(
        self, request: web.Request
    ) -> web.StreamResponse:
        if err := self._check_auth(request):
            return err
        try:
            inline = request.query.get("inline") == "1"
            metadata = await self._project_controller.project_file_download_url(
                request.match_info["project_id"],
                request.match_info["file_id"],
                inline=inline,
            )
            return await self._proxy_asset_metadata(request, metadata, inline=inline)
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_conversation(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            raw = await self._driver.get_conversation(
                request.match_info["conversation_id"]
            )
            if not raw:
                return web.json_response(
                    {"error": {"message": "Conversation not found"}},
                    status=404,
                )
            data = normalize_client_conversation(raw)
            if request.query.get("raw") == "1":
                return web.json_response(
                    {"object": "conversation", "data": data, "raw": raw}
                )
            return web.json_response({"object": "conversation", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _fetch_snapshot(self, conversation_id: str) -> dict | None:
        """Fetch a client-safe snapshot for rich send completion events."""
        if not conversation_id:
            return None
        for attempt in range(6):
            try:
                raw = await self._driver.get_conversation(conversation_id)
                if raw and raw.get("mapping"):
                    return normalize_client_conversation(raw)
            except AuthExpiredError:
                raise
            except Exception:
                pass
            if attempt < 5:
                await asyncio.sleep(0.4 + 0.2 * attempt)
        return None

    async def _handle_asset_download(
        self, request: web.Request
    ) -> web.StreamResponse:
        if err := self._check_auth(request):
            return err
        pointer = urllib.parse.unquote(request.match_info["asset_pointer"])
        conversation_id = request.query.get("conversation_id")
        try:
            inline = request.query.get("inline") == "1"
            metadata = await self._parity_actions.asset_download_url(
                pointer,
                conversation_id=conversation_id,
                inline=inline,
            )
            return await self._proxy_asset_metadata(request, metadata, inline=inline)
        except Exception as exc:
            return self._parity_error(exc)

    async def _proxy_asset_metadata(
        self,
        request: web.Request,
        metadata: dict[str, Any],
        *,
        inline: bool,
    ) -> web.StreamResponse:
        url = str(metadata.get("download_url") or "")
        if not _is_allowed_asset_url(url):
            raise ParityBrowserError(
                "ChatGPT returned an asset URL outside the allowed OpenAI hosts"
            )

        timeout = aiohttp.ClientTimeout(
            total=None,
            sock_connect=30,
            sock_read=120,
        )
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url, allow_redirects=False) as upstream:
                if 300 <= upstream.status < 400:
                    raise ParityBrowserError(
                        "ChatGPT asset URL attempted an unexpected redirect"
                    )
                if upstream.status >= 400:
                    preview = (await upstream.text())[:300]
                    raise ParityBrowserError(
                        "ChatGPT asset download failed "
                        f"({upstream.status}): {preview}"
                    )

                headers: dict[str, str] = {
                    "X-Content-Type-Options": "nosniff",
                }
                if content_type := upstream.headers.get("Content-Type"):
                    headers["Content-Type"] = content_type
                if content_length := upstream.headers.get("Content-Length"):
                    headers["Content-Length"] = content_length
                file_name = metadata.get("file_name")
                if file_name:
                    encoded = urllib.parse.quote(str(file_name), safe="")
                    disposition = "inline" if inline else "attachment"
                    headers["Content-Disposition"] = (
                        f"{disposition}; filename*=UTF-8''{encoded}"
                    )

                response = web.StreamResponse(status=200, headers=headers)
                await response.prepare(request)
                async for chunk in upstream.content.iter_chunked(1024 * 1024):
                    await response.write(chunk)
                await response.write_eof()
                return response


def _is_allowed_asset_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return False
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        return False
    if parsed.username or parsed.password:
        return False
    host = parsed.hostname.rstrip(".").lower()
    if host in _ALLOWED_ASSET_HOST_EXACT:
        return True
    return any(
        host == suffix or host.endswith("." + suffix)
        for suffix in _ALLOWED_ASSET_HOST_SUFFIXES
    )
