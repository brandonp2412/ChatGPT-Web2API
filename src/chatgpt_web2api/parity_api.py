"""Unified REST surface for a first-party-like ChatGPT chat client.

This extends the existing OpenAI-compatible API rather than replacing it.  The
legacy endpoints remain unchanged; `/v1/chat/*`, conversations, attachments,
voice and assets provide the richer semantics required by the Flutter client.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import urllib.parse
import uuid
from typing import Any

import aiohttp
from aiohttp import web

from .api_server import APIServer, MODEL_MAP
from .cdp_driver import AuthExpiredError, GenerationStuckError, RateLimitError
from .lock_resolver import MutationLock, OwnedTabRequiredError, resolve_mutation_lock
from .parity_actions import ParityActions
from .parity_browser import (
    MAX_ATTACHMENT_BYTES,
    AttachmentStore,
    AttachmentTooLargeError,
    ParityBrowser,
    ParityBrowserError,
    StoredAttachment,
)
from .parity_models import normalize_conversation

logger = logging.getLogger(__name__)


class ParityAPIServer(APIServer):
    """APIServer plus the normal ChatGPT chat-window feature surface."""

    def __init__(self, config, driver, breakers=None) -> None:
        super().__init__(config, driver, breakers=breakers)
        self._parity_browser = ParityBrowser(driver)
        self._parity_actions = ParityActions(driver)
        self._attachments = AttachmentStore()

        # aiohttp's request parser enforces this value before handlers run.
        # Leave a little envelope above ChatGPT's per-file hard limit for
        # multipart framing/headers.
        self.app._client_max_size = MAX_ATTACHMENT_BYTES + 2 * 1024 * 1024
        self.app.on_cleanup.append(self._cleanup_parity)

        # Read / account surface.
        self.app.router.add_get("/v1/capabilities", self._handle_capabilities)
        self.app.router.add_get("/v1/conversations/search", self._handle_conversation_search)
        self.app.router.add_get("/v1/conversations", self._handle_conversations)
        self.app.router.add_get("/v1/conversations/{conversation_id}", self._handle_conversation)
        self.app.router.add_patch("/v1/conversations/{conversation_id}", self._handle_conversation_patch)
        self.app.router.add_delete("/v1/conversations/{conversation_id}", self._handle_conversation_delete)
        self.app.router.add_post(
            "/v1/conversations/{conversation_id}/actions", self._handle_message_action
        )
        self.app.router.add_get("/v1/gpts", self._handle_gpts)
        self.app.router.add_get("/v1/memories", self._handle_memories)
        self.app.router.add_get("/v1/projects/{project_id}", self._handle_project)
        self.app.router.add_get("/v1/projects/{project_id}/files", self._handle_project_files)

        # Composer / file / generation surface.
        self.app.router.add_post("/v1/attachments", self._handle_attachment_upload)
        self.app.router.add_delete("/v1/attachments/{attachment_id}", self._handle_attachment_delete)
        self.app.router.add_get("/v1/assets/{asset_pointer:.*}", self._handle_asset_download)
        self.app.router.add_post("/v1/chat/send", self._handle_rich_send)
        self.app.router.add_post("/v1/chat/stop", self._handle_stop)

        # Voice: Flutter terminates WebRTC; this backend only authenticates the
        # SDP exchange and provides attachment pointers for DataChannel relay.
        self.app.router.add_post("/v1/voice/session", self._handle_voice_session)
        self.app.router.add_post("/v1/voice/attachments", self._handle_voice_attachment)

    async def _cleanup_parity(self, _app: web.Application) -> None:
        await self._attachments.close()

    # ── Discovery ────────────────────────────────────────────

    async def _handle_capabilities(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        return web.json_response(
            {
                "schema": "chatgpt-parity.v1",
                "conversation_tree": True,
                "conversation_search": True,
                "attachments": True,
                "image_input": True,
                "image_generation": True,
                "image_edit": True,
                "search": True,
                "deep_research": True,
                "study": True,
                "data_analysis": True,
                "voice": True,
                "projects": True,
                "custom_gpts": True,
                "memory": True,
                "message_actions": {"edit": True, "regenerate": True, "branch": True},
                "streaming": "sse",
                "transport": "chatgpt-spa-cdp",
            }
        )

    # ── Conversations ────────────────────────────────────────

    async def _handle_conversations(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            offset = max(0, int(request.query.get("offset", "0")))
            limit = min(100, max(1, int(request.query.get("limit", "50"))))
            order = request.query.get("order", "updated")
            items = await self._driver.get_conversations(offset=offset, limit=limit, order=order)
            return web.json_response({"object": "list", "data": items, "offset": offset, "limit": limit})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_conversation_search(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        query = request.query.get("query", "").strip()
        if not query:
            return self._bad_request("query is required")
        try:
            result = await self._parity_actions.search_conversations(
                query, cursor=request.query.get("cursor")
            )
            return web.json_response(result)
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_conversation(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            raw = await self._driver.get_conversation(request.match_info["conversation_id"])
            if not raw:
                return web.json_response({"error": {"message": "Conversation not found"}}, status=404)
            data = normalize_conversation(raw)
            if request.query.get("raw") == "1":
                return web.json_response({"object": "conversation", "data": data, "raw": raw})
            return web.json_response({"object": "conversation", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_conversation_patch(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        conversation_id = request.match_info["conversation_id"]
        try:
            body = await self._json_body(request)
            if "title" not in body and "archived" not in body:
                return self._bad_request("title or archived is required")
            if "title" in body:
                title = str(body["title"]).strip()
                if not title:
                    return self._bad_request("title cannot be empty")
                if not await self._driver.rename_conversation(conversation_id, title):
                    raise ParityBrowserError("ChatGPT did not accept conversation rename")
            if "archived" in body:
                if not await self._driver.archive_conversation(
                    conversation_id, bool(body["archived"])
                ):
                    raise ParityBrowserError("ChatGPT did not accept archive update")
            raw = await self._driver.get_conversation(conversation_id)
            return web.json_response(
                {"object": "conversation", "data": normalize_conversation(raw)}
            )
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_conversation_delete(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            deleted = await self._driver.delete_conversation(request.match_info["conversation_id"])
            if not deleted:
                return web.json_response({"error": {"message": "Delete failed"}}, status=502)
            return web.json_response({"deleted": True})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_message_action(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        conversation_id = request.match_info["conversation_id"]
        try:
            body = await self._json_body(request)
            action = str(body.get("action") or "").strip().lower()
            message_id = _optional_string(body.get("message_id"))
            replacement = _optional_string(body.get("text"))
            if action not in {"edit", "regenerate", "branch"}:
                return self._bad_request("action must be edit, regenerate, or branch")
            if action == "edit" and not replacement:
                return self._bad_request("text is required for edit")

            before = await self._driver.get_conversation(conversation_id)
            if not before:
                return web.json_response({"error": {"message": "Conversation not found"}}, status=404)
            normalized_before = normalize_conversation(before)
            message_text = self._message_text(normalized_before, message_id)

            async with self._mutation_guard():
                await self._parity_actions.trigger_message_action(
                    action,
                    conversation_id=conversation_id,
                    message_id=message_id,
                    message_text=message_text,
                    replacement_text=replacement,
                )

                if action == "branch":
                    branched = await self._wait_for_new_conversation_url(conversation_id)
                    if not branched:
                        raise ParityBrowserError("ChatGPT did not navigate to the branched chat")
                    fresh = await self._wait_for_conversation_available(branched)
                    return web.json_response({"object": "conversation", "data": fresh})

                fresh = await self._parity_actions.wait_for_conversation_change(
                    conversation_id,
                    previous_current_node=_optional_string(before.get("current_node")),
                    timeout=self._action_timeout(body),
                )
                return web.json_response({"object": "conversation", "data": fresh})
        except Exception as exc:
            return self._parity_error(exc)

    # ── Account context ──────────────────────────────────────

    async def _handle_gpts(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            return web.json_response({"object": "list", "data": await self._driver.list_gpts()})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_memories(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            return web.json_response({"object": "list", "data": await self._driver.get_memories()})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_project(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            data = await self._driver.get_project_detail(request.match_info["project_id"])
            return web.json_response({"object": "project", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_project_files(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            data = await self._driver.get_project_files(request.match_info["project_id"])
            return web.json_response({"object": "list", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    # ── Attachments / assets ─────────────────────────────────

    async def _handle_attachment_upload(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            reader = await request.multipart()
            file_field = None
            while True:
                field = await reader.next()
                if field is None:
                    break
                if getattr(field, "filename", None):
                    file_field = field
                    break
            if file_field is None:
                return self._bad_request("multipart file field is required")
            item = await self._attachments.put_multipart_field(file_field)
            return web.json_response({"object": "attachment", "data": item.public_dict()}, status=201)
        except AttachmentTooLargeError as exc:
            return web.json_response({"error": {"message": str(exc), "type": "file_too_large"}}, status=413)
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_attachment_delete(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        deleted = await self._attachments.delete(request.match_info["attachment_id"])
        return web.json_response({"deleted": deleted}, status=200 if deleted else 404)

    async def _handle_asset_download(self, request: web.Request) -> web.StreamResponse:
        if err := self._check_auth(request):
            return err
        pointer = urllib.parse.unquote(request.match_info["asset_pointer"])
        conversation_id = request.query.get("conversation_id")
        try:
            metadata = await self._parity_actions.asset_download_url(
                pointer,
                conversation_id=conversation_id,
                inline=request.query.get("inline") == "1",
            )
            url = str(metadata.get("download_url") or "")
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme != "https" or not parsed.netloc:
                raise ParityBrowserError("ChatGPT returned an invalid asset download URL")

            timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=120)
            session = aiohttp.ClientSession(timeout=timeout)
            try:
                upstream = await session.get(url, allow_redirects=True)
                if upstream.status >= 400:
                    preview = (await upstream.text())[:300]
                    await upstream.release()
                    await session.close()
                    raise ParityBrowserError(
                        f"ChatGPT asset download failed ({upstream.status}): {preview}"
                    )
                headers = {}
                if content_type := upstream.headers.get("Content-Type"):
                    headers["Content-Type"] = content_type
                file_name = metadata.get("file_name")
                if file_name:
                    encoded = urllib.parse.quote(str(file_name), safe="")
                    headers["Content-Disposition"] = f"inline; filename*=UTF-8''{encoded}"
                response = web.StreamResponse(status=200, headers=headers)
                await response.prepare(request)
                async for chunk in upstream.content.iter_chunked(1024 * 1024):
                    await response.write(chunk)
                await response.write_eof()
                await upstream.release()
                await session.close()
                return response
            except Exception:
                if not session.closed:
                    await session.close()
                raise
        except Exception as exc:
            return self._parity_error(exc)

    # ── Rich composer send ───────────────────────────────────

    async def _handle_rich_send(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        self._request_count += 1
        attachment_ids: list[str] = []
        try:
            body = await self._json_body(request)
            prompt = str(body.get("prompt") or "").strip()
            raw_attachment_ids = body.get("attachment_ids") or []
            if not isinstance(raw_attachment_ids, list) or not all(
                isinstance(item, str) for item in raw_attachment_ids
            ):
                return self._bad_request("attachment_ids must be a list of strings")
            attachment_ids = list(dict.fromkeys(raw_attachment_ids))
            if not prompt and not attachment_ids:
                return self._bad_request("prompt or attachment_ids is required")
            attachments = await self._attachments.get_many(attachment_ids)
            return await self._execute_rich_send(request, body, prompt, attachments)
        except Exception as exc:
            return self._parity_error(exc)
        finally:
            if attachment_ids:
                await self._attachments.delete_many(attachment_ids)

    async def _execute_rich_send(
        self,
        request: web.Request,
        body: dict[str, Any],
        prompt: str,
        attachments: list[StoredAttachment],
    ) -> web.Response:
        model = str(body.get("model") or self._config.chatgpt.default_model)
        model_slug = MODEL_MAP.get(model, model)
        conversation_id = _optional_string(body.get("conversation_id"))
        project_id = _optional_string(body.get("project_id"))
        gizmo_id = _optional_string(body.get("gizmo_id"))
        mode = _optional_string(body.get("mode")) or "normal"
        stream = body.get("stream", True) is not False
        timeout = self._send_timeout(body, mode)

        async with self._mutation_guard():
            if model_slug and model_slug != "auto":
                selected = await self._driver.select_model(model_slug)
                if not selected:
                    logger.warning("Parity send could not select model %s; using active model", model_slug)

            if conversation_id:
                await self._driver.navigate_conversation(conversation_id)
            elif gizmo_id and not project_id:
                await self._driver.navigate_gpt(gizmo_id)
            else:
                await self._driver.navigate_new_chat(gizmo_id=project_id)
                self._last_project_id = project_id

            await self._parity_browser.select_tool(mode)
            await self._parity_browser.attach_files(attachments)

            if stream:
                return await self._stream_rich_response(
                    request, model_slug, prompt, timeout, mode=mode
                )
            return await self._full_rich_response(model_slug, prompt, timeout, mode=mode)

    async def _full_rich_response(
        self, model: str, prompt: str, timeout: float, *, mode: str
    ) -> web.Response:
        text = ""
        finish_reason = "stop"
        async for chunk in self._driver.send_and_stream(
            prompt, timeout=timeout, model=model
        ):
            text += chunk.delta
            if chunk.finish_reason:
                finish_reason = chunk.finish_reason
        conversation_id = self._driver._current_conv_id or ""
        self._last_conv_id = conversation_id or self._last_conv_id
        self._last_successful_send_at = time.time()
        snapshot = await self._fetch_snapshot(conversation_id)
        return web.json_response(
            {
                "id": "chatparity-" + uuid.uuid4().hex,
                "object": "chat.parity.response",
                "model": model,
                "mode": mode,
                "conversation_id": conversation_id,
                "text": text,
                "finish_reason": finish_reason,
                "conversation": snapshot,
            }
        )

    async def _stream_rich_response(
        self,
        request: web.Request,
        model: str,
        prompt: str,
        timeout: float,
        *,
        mode: str,
    ) -> web.StreamResponse:
        response = web.StreamResponse(
            headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            }
        )
        await response.prepare(request)
        response_id = "chatparity-" + uuid.uuid4().hex
        await self._send_parity_event(
            response,
            {"type": "response.started", "id": response_id, "model": model, "mode": mode},
        )
        conversation_id = ""
        finish_reason = "stop"
        try:
            async for chunk in self._driver.send_and_stream(
                prompt, timeout=timeout, model=model
            ):
                if chunk.delta:
                    await self._send_parity_event(
                        response,
                        {"type": "message.delta", "id": response_id, "text": chunk.delta},
                    )
                if chunk.finish_reason:
                    finish_reason = chunk.finish_reason
                    conversation_id = self._driver._current_conv_id or ""
            conversation_id = conversation_id or self._driver._current_conv_id or ""
            self._last_conv_id = conversation_id or self._last_conv_id
            self._last_successful_send_at = time.time()
            snapshot = await self._fetch_snapshot(conversation_id)
            await self._send_parity_event(
                response,
                {
                    "type": "response.completed",
                    "id": response_id,
                    "conversation_id": conversation_id,
                    "finish_reason": finish_reason,
                },
            )
            if snapshot:
                await self._send_parity_event(
                    response,
                    {
                        "type": "conversation.snapshot",
                        "conversation_id": conversation_id,
                        "conversation": snapshot,
                    },
                )
        except ConnectionResetError:
            await self._parity_browser.stop_generation(conversation_id or None)
            return response
        except asyncio.CancelledError:
            await self._parity_browser.stop_generation(conversation_id or None)
            raise
        except Exception as exc:
            logger.exception("Rich parity stream failed")
            await self._send_parity_event(
                response,
                {"type": "response.error", "id": response_id, **self._stream_error_payload(exc)},
            )
        try:
            await response.write(b"data: [DONE]\n\n")
            await response.write_eof()
        except ConnectionResetError:
            pass
        return response

    async def _handle_stop(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            stopped = await self._parity_browser.stop_generation(
                _optional_string(body.get("conversation_id"))
            )
            return web.json_response({"stopped": stopped})
        except Exception as exc:
            return self._parity_error(exc)

    # ── Voice ────────────────────────────────────────────────

    async def _handle_voice_session(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            sdp = str(body.get("offer_sdp") or "")
            if not sdp:
                return self._bad_request("offer_sdp is required")
            result = await self._parity_browser.create_voice_session(
                sdp,
                voice=str(body.get("voice") or "cove"),
                voice_mode=str(body.get("voice_mode") or "wingman"),
                language_code=str(body.get("language_code") or "auto"),
            )
            return web.json_response(result)
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_voice_attachment(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        attachment_id = ""
        try:
            body = await self._json_body(request)
            attachment_id = str(body.get("attachment_id") or "")
            if not attachment_id:
                return self._bad_request("attachment_id is required")
            attachments = await self._attachments.get_many([attachment_id])
            result = await self._parity_browser.upload_file_direct(attachments[0])
            result["asset_pointer"] = "sediment://" + str(result["file_id"])
            return web.json_response({"object": "voice.attachment", "data": result})
        except Exception as exc:
            return self._parity_error(exc)
        finally:
            if attachment_id:
                await self._attachments.delete(attachment_id)

    # ── Internal helpers ─────────────────────────────────────

    def _mutation_guard(self) -> MutationLock:
        """Return the same cross-process lock policy used by the base chat API."""
        if self._parallel_tabs:
            port, key = resolve_mutation_lock(self._driver, True)
        else:
            port, key = self._cdp_port, None
        return MutationLock(port, key)

    async def _fetch_snapshot(self, conversation_id: str) -> dict[str, Any] | None:
        if not conversation_id:
            return None
        for attempt in range(6):
            try:
                raw = await self._driver.get_conversation(conversation_id)
                if raw and raw.get("mapping"):
                    return normalize_conversation(raw)
            except AuthExpiredError:
                raise
            except Exception:
                logger.debug("Conversation snapshot read raced persistence", exc_info=True)
            if attempt < 5:
                await asyncio.sleep(0.4 + 0.2 * attempt)
        return None

    async def _wait_for_new_conversation_url(
        self, old_conversation_id: str, *, timeout: float = 20
    ) -> str | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            current = await self._parity_actions.current_conversation_id_from_url()
            if current and current != old_conversation_id:
                return current
            await asyncio.sleep(0.25)
        return None

    async def _wait_for_conversation_available(
        self, conversation_id: str, *, timeout: float = 30
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            raw = await self._driver.get_conversation(conversation_id)
            if raw and raw.get("mapping"):
                return normalize_conversation(raw)
            await asyncio.sleep(0.5)
        raise ParityBrowserError("Branched conversation did not become readable")

    @staticmethod
    async def _send_parity_event(response: web.StreamResponse, data: dict[str, Any]) -> None:
        await response.write(f"data: {json.dumps(data, ensure_ascii=False)}\n\n".encode("utf-8"))

    @staticmethod
    def _message_text(conversation: dict[str, Any], message_id: str | None) -> str | None:
        if not message_id:
            return None
        for message in conversation.get("messages") or []:
            if message.get("id") == message_id or message.get("node_id") == message_id:
                return _optional_string(message.get("text"))
        return None

    def _send_timeout(self, body: dict[str, Any], mode: str) -> float:
        default = float(self._config.server.request_timeout)
        if mode.strip().lower().replace("-", "_") == "deep_research":
            default = max(default, 900.0)
        requested = body.get("timeout")
        if isinstance(requested, (int, float)) and not isinstance(requested, bool):
            return min(1800.0, max(1.0, float(requested)))
        return min(1800.0, default)

    @staticmethod
    def _action_timeout(body: dict[str, Any]) -> float:
        requested = body.get("timeout")
        if isinstance(requested, (int, float)) and not isinstance(requested, bool):
            return min(900.0, max(1.0, float(requested)))
        return 240.0

    @staticmethod
    async def _json_body(request: web.Request) -> dict[str, Any]:
        try:
            value = await request.json()
        except (json.JSONDecodeError, ValueError) as exc:
            raise ParityBrowserError("Invalid JSON body") from exc
        if not isinstance(value, dict):
            raise ParityBrowserError("JSON body must be an object")
        return value

    @staticmethod
    def _bad_request(message: str) -> web.Response:
        return web.json_response(
            {"error": {"message": message, "type": "invalid_request_error"}}, status=400
        )

    def _parity_error(self, exc: Exception) -> web.Response:
        if isinstance(exc, (RateLimitError, AuthExpiredError, GenerationStuckError, OwnedTabRequiredError)):
            return self._error_response(exc)
        if isinstance(exc, AttachmentTooLargeError):
            return web.json_response({"error": {"message": str(exc)}}, status=413)
        if isinstance(exc, ParityBrowserError):
            return web.json_response(
                {"error": {"message": str(exc), "type": "chatgpt_parity_error"}}, status=502
            )
        logger.exception("Parity API error")
        return self._error_response(exc)

    @staticmethod
    def _stream_error_payload(exc: Exception) -> dict[str, Any]:
        if isinstance(exc, RateLimitError):
            return {
                "error": "rate_limit_exceeded",
                "message": str(exc),
                "retry_after": exc.retry_after,
            }
        if isinstance(exc, AuthExpiredError):
            return {"error": "auth_expired", "message": str(exc)}
        if isinstance(exc, GenerationStuckError):
            return {
                "error": "generation_stuck",
                "message": str(exc),
                "phase": exc.phase,
                "stalled_for_s": exc.stalled_for_s,
            }
        return {"error": type(exc).__name__, "message": str(exc)}


def _optional_string(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
