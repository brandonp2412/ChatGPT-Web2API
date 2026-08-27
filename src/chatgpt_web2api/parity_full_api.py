"""Hardened, full ChatGPT chat-window parity REST surface.

This class layers product-level operations on :class:`ParityAPIServer` while
preserving the mature legacy API and CDP reliability machinery. It remains one
server process, one Chrome session, and one account/session boundary.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import urllib.parse
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import aiohttp
from aiohttp import web

from .api_server import MODEL_MAP
from .cdp_driver import AuthExpiredError, GenerationStuckError, RateLimitError
from .lock_resolver import MutationLock, OwnedTabRequiredError, resolve_mutation_lock
from .parity_api import ParityAPIServer
from .parity_browser import ParityBrowserError, StoredAttachment
from .parity_extras import ParityExtras
from .parity_models import normalize_conversation

logger = logging.getLogger(__name__)


class FullParityAPIServer(ParityAPIServer):
    """Single-backend API for the normal ChatGPT Chat experience."""

    def __init__(self, config, driver, breakers=None) -> None:
        super().__init__(config, driver, breakers=breakers)
        self._parity_extras = ParityExtras(driver)

        self.app.router.add_get("/v1/tools", self._handle_tools)
        self.app.router.add_get("/v1/tasks", self._handle_tasks)
        self.app.router.add_get("/v1/pins", self._handle_pins)
        self.app.router.add_patch(
            "/v1/conversations/{conversation_id}/pin", self._handle_pin
        )
        self.app.router.add_post(
            "/v1/conversations/{conversation_id}/feedback", self._handle_feedback
        )
        self.app.router.add_post(
            "/v1/conversations/{conversation_id}/share", self._handle_share
        )
        self.app.router.add_delete("/v1/shares/{share_id}", self._handle_share_delete)

        self.app.router.add_post("/v1/projects", self._handle_project_create)
        self.app.router.add_patch("/v1/projects/{project_id}", self._handle_project_update)
        self.app.router.add_delete("/v1/projects/{project_id}", self._handle_project_delete)
        self.app.router.add_post("/v1/memories", self._handle_memory_create)
        self.app.router.add_delete("/v1/memories/{memory_id}", self._handle_memory_delete)

        self.app.router.add_post(
            "/v1/conversations/{conversation_id}/blocks/{message_id}/actions",
            self._handle_block_action,
        )

    # ── Capability / dynamic tool discovery ──────────────────

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
                "plugins": True,
                "temporary_chat": True,
                "pins": True,
                "share": True,
                "feedback": True,
                "writing_blocks": True,
                "code_blocks": {"edit": True, "preview": True, "run": True},
                "legacy_canvas": "model_dependent",
                "message_actions": {
                    "edit": True,
                    "regenerate": True,
                    "branch": True,
                    "copy": "client_side",
                    "read_aloud": "client_side_or_voice",
                },
                "dynamic_tools_url": "/v1/tools",
                "background_tasks_url": "/v1/tasks",
                "streaming": "sse",
                "transport": "chatgpt-spa-cdp",
            }
        )

    async def _handle_tools(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            async with self._mutation_guard():
                tools = await self._parity_browser.discover_composer_tools()
            return web.json_response({"object": "list", "data": tools})
        except Exception as exc:
            return self._parity_error(exc)

    # ── Chat sidebar / message chrome ────────────────────────

    async def _handle_tasks(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            data = await self._parity_extras.tasks()
            conversation_id = request.query.get("conversation_id")
            if conversation_id:
                data = _filter_tasks(data, conversation_id)
            return web.json_response({"object": "tasks", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_pins(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            return web.json_response({"object": "pins", "data": await self._parity_extras.pins()})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_pin(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            if "pinned" not in body or not isinstance(body["pinned"], bool):
                return self._bad_request("pinned boolean is required")
            async with self._mutation_guard():
                await self._parity_extras.set_pin(
                    request.match_info["conversation_id"], body["pinned"]
                )
            return web.json_response({"pinned": body["pinned"]})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_feedback(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            message_id = _optional_string(body.get("message_id"))
            rating = _optional_string(body.get("rating"))
            if not message_id or not rating:
                return self._bad_request("message_id and rating are required")
            tags_raw = body.get("tags")
            if tags_raw is not None and (
                not isinstance(tags_raw, list)
                or not all(isinstance(item, str) for item in tags_raw)
            ):
                return self._bad_request("tags must be a list of strings")
            async with self._mutation_guard():
                data = await self._parity_extras.feedback(
                    conversation_id=request.match_info["conversation_id"],
                    message_id=message_id,
                    rating=rating,
                    text=_optional_string(body.get("text")),
                    tags=tags_raw,
                )
            return web.json_response({"object": "feedback", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_share(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        conversation_id = request.match_info["conversation_id"]
        try:
            body = await self._json_body(request)
            raw = await self._driver.get_conversation(conversation_id)
            current_node = _optional_string(raw.get("current_node")) if raw else None
            if not current_node:
                return web.json_response(
                    {"error": {"message": "Conversation not found or has no current node"}},
                    status=404,
                )
            async with self._mutation_guard():
                data = await self._parity_extras.create_share(
                    conversation_id=conversation_id,
                    current_node_id=current_node,
                    anonymous=body.get("anonymous", True) is not False,
                )
            return web.json_response({"object": "share", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_share_delete(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            async with self._mutation_guard():
                deleted = await self._parity_extras.delete_share(request.match_info["share_id"])
            return web.json_response({"deleted": deleted})
        except Exception as exc:
            return self._parity_error(exc)

    # ── Projects / memory ────────────────────────────────────

    async def _handle_project_create(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            name = _optional_string(body.get("name"))
            if not name:
                return self._bad_request("name is required")
            memory_scope = _optional_string(body.get("memory_scope")) or "project_v2"
            async with self._mutation_guard():
                data = await self._driver.create_project(
                    name,
                    _optional_string(body.get("instructions")) or "",
                    memory_scope,
                )
            return web.json_response({"object": "project", "data": data}, status=201)
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_project_update(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        project_id = request.match_info["project_id"]
        try:
            body = await self._json_body(request)
            if "instructions" not in body:
                return self._bad_request("instructions is required")
            instructions = str(body.get("instructions") or "")
            async with self._mutation_guard():
                ok = await self._driver.update_project_instructions(project_id, instructions)
            if not ok:
                raise ParityBrowserError("ChatGPT did not accept project instructions")
            data = await self._driver.get_project_detail(project_id)
            return web.json_response({"object": "project", "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_project_delete(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            async with self._mutation_guard():
                data = await self._driver.delete_project(request.match_info["project_id"])
            return web.json_response({"deleted": True, "data": data})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_memory_create(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            content = _optional_string(body.get("content"))
            if not content:
                return self._bad_request("content is required")
            async with self._mutation_guard():
                data = await self._driver.create_memory(content)
            return web.json_response({"object": "memory", "data": data}, status=201)
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_memory_delete(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            async with self._mutation_guard():
                deleted = await self._driver.delete_memory(request.match_info["memory_id"])
            if not deleted:
                return web.json_response({"error": {"message": "Memory delete failed"}}, status=502)
            return web.json_response({"deleted": True})
        except Exception as exc:
            return self._parity_error(exc)

    # ── Editable writing/code blocks ─────────────────────────

    async def _handle_block_action(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        conversation_id = request.match_info["conversation_id"]
        message_id = request.match_info["message_id"]
        try:
            body = await self._json_body(request)
            action = str(body.get("action") or "").strip().lower()
            if action not in {"edit", "run", "preview", "open"}:
                return self._bad_request("action must be edit, run, preview, or open")
            text = _optional_string(body.get("text"))
            if action == "edit" and text is None:
                return self._bad_request("text is required for edit")
            async with self._mutation_guard():
                await self._driver.navigate_conversation(conversation_id)
                result = await self._run_block_ui_action(message_id, action, text)
            await asyncio.sleep(0.5)
            raw = await self._driver.get_conversation(conversation_id)
            snapshot = normalize_conversation(raw) if raw else None
            return web.json_response(
                {"object": "block.action", "data": result, "conversation": snapshot}
            )
        except Exception as exc:
            return self._parity_error(exc)

    async def _run_block_ui_action(
        self,
        message_id: str,
        action: str,
        text: str | None,
    ) -> dict[str, Any]:
        raw = await self._driver._js_with_data_strict(
            """(async () => {
              const norm = s => (s || '').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible = el => { const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'; };
              const label = el => norm([el.innerText,el.textContent,el.getAttribute('aria-label'),
                el.getAttribute('title'),el.getAttribute('data-testid')].filter(Boolean).join(' '));
              let target = document.querySelector('[data-message-id="' + CSS.escape(__D.message_id) + '"]');
              if (!target) {
                const candidates = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
                target = candidates[candidates.length - 1] || null;
              }
              if (!target) return JSON.stringify({ok:false,stage:'message'});
              target.scrollIntoView({block:'center'});
              const aliases = {
                edit:['edit','edit code','edit block'], run:['run','run code'],
                preview:['preview','show preview'], open:['open','open full screen','expand']
              }[__D.action];
              const controls = root => [...root.querySelectorAll('button,[role="button"],[data-testid]')].filter(visible);
              let button = controls(target).find(el => aliases.some(a => label(el) === a || label(el).includes(a)));
              if (!button) button = controls(document).find(el => aliases.some(a => label(el) === a));
              if (!button) return JSON.stringify({ok:false,stage:'action'});
              button.click();
              if (__D.action !== 'edit') return JSON.stringify({ok:true,stage:'triggered',label:label(button)});
              await new Promise(r => setTimeout(r,300));
              const editors = [...document.querySelectorAll('textarea,[contenteditable="true"]')].filter(visible);
              const editor = editors[editors.length - 1];
              if (!editor) return JSON.stringify({ok:false,stage:'editor'});
              editor.focus();
              if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) {
                const proto = editor instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto,'value')?.set;
                if (setter) setter.call(editor,__D.text); else editor.value=__D.text;
                editor.dispatchEvent(new Event('input',{bubbles:true}));
              } else {
                const range=document.createRange(); range.selectNodeContents(editor);
                const sel=getSelection(); sel.removeAllRanges(); sel.addRange(range);
                document.execCommand('insertText',false,__D.text);
                editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:__D.text}));
              }
              await new Promise(r => setTimeout(r,150));
              const save = controls(document).find(el => /save|done|apply/.test(label(el)));
              if (save) save.click(); else editor.blur();
              return JSON.stringify({ok:true,stage:'edited'});
            })()""",
            {"message_id": message_id, "action": action, "text": text or ""},
            timeout=15,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT block {action} failed at {result.get('stage', 'unknown')}"
            )
        return result

    # ── Rich send overrides ──────────────────────────────────

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
        plugin = _optional_string(body.get("plugin"))
        mode = _optional_string(body.get("mode")) or "normal"
        stream = body.get("stream", True) is not False
        timeout = self._send_timeout(body, mode)

        if conversation_id and body.get("temporary") is True:
            return self._bad_request("Temporary Chat can only be selected when starting a new chat")

        async with self._mutation_guard():
            if model_slug and model_slug != "auto":
                selected = await self._driver.select_model(model_slug)
                if not selected:
                    logger.warning(
                        "Parity send could not select model %s; using active model", model_slug
                    )

            if conversation_id:
                await self._driver.navigate_conversation(conversation_id)
            elif gizmo_id and not project_id:
                await self._driver.navigate_gpt(gizmo_id)
            else:
                await self._driver.navigate_new_chat(gizmo_id=project_id)
                self._last_project_id = project_id
                if "temporary" in body:
                    await self._parity_browser.set_temporary_chat(
                        body.get("temporary") is True,
                        personalized=body.get("temporary_personalized") is True,
                    )

            await self._parity_browser.select_tool(mode)
            if plugin:
                await self._parity_browser.select_plugin(plugin)
            await self._parity_browser.attach_files(attachments)

            if stream:
                return await self._stream_rich_response(
                    request, model_slug, prompt, timeout, mode=mode
                )
            return await self._full_rich_response(model_slug, prompt, timeout, mode=mode)

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

        queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
        conversation_id = ""
        finish_reason = "stop"

        async def consume_generation() -> None:
            try:
                async for chunk in self._driver.send_and_stream(
                    prompt, timeout=timeout, model=model
                ):
                    await queue.put(("chunk", chunk))
            except Exception as exc:
                await queue.put(("error", exc))
            finally:
                await queue.put(("done", None))

        consumer = asyncio.create_task(consume_generation())
        poll_tasks = _mode_has_background_tasks(mode)
        last_task_fingerprint = ""
        try:
            done = False
            while not done:
                try:
                    kind, value = await asyncio.wait_for(queue.get(), timeout=0.8)
                except TimeoutError:
                    kind, value = "tick", None

                if kind == "chunk":
                    chunk = value
                    if chunk.delta:
                        await self._send_parity_event(
                            response,
                            {"type": "message.delta", "id": response_id, "text": chunk.delta},
                        )
                    if chunk.finish_reason:
                        finish_reason = chunk.finish_reason
                        conversation_id = self._driver._current_conv_id or conversation_id
                elif kind == "error":
                    raise value
                elif kind == "done":
                    done = True

                if poll_tasks and not done:
                    try:
                        tasks = await self._parity_extras.tasks()
                        fingerprint = json.dumps(tasks, sort_keys=True, default=str)
                        if fingerprint != last_task_fingerprint:
                            last_task_fingerprint = fingerprint
                            await self._send_parity_event(
                                response,
                                {"type": "tool.progress", "id": response_id, "tasks": tasks},
                            )
                    except Exception:
                        logger.debug("Background task progress read failed", exc_info=True)

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
        except (ConnectionResetError, asyncio.CancelledError):
            consumer.cancel()
            await self._parity_browser.stop_generation(conversation_id or None)
            if isinstance(asyncio.current_task(), asyncio.Task) and False:
                pass
            if isinstance(_, type(None)):
                pass
            # CancelledError must propagate so aiohttp can tear down cleanly.
            if isinstance(asyncio.current_task(), asyncio.Task) and asyncio.current_task().cancelled():
                raise
            return response
        except Exception as exc:
            logger.exception("Rich parity stream failed")
            if not consumer.done():
                consumer.cancel()
            await self._send_parity_event(
                response,
                {"type": "response.error", "id": response_id, **self._stream_error_payload(exc)},
            )
        finally:
            if not consumer.done():
                consumer.cancel()
            try:
                await consumer
            except (asyncio.CancelledError, Exception):
                pass

        try:
            await response.write(b"data: [DONE]\n\n")
            await response.write_eof()
        except ConnectionResetError:
            pass
        return response

    # ── Hardened base overrides ──────────────────────────────

    @asynccontextmanager
    async def _mutation_guard(self) -> AsyncIterator[None]:
        """Exactly mirror base send's breaker, lock and target-drift guards."""
        await self._check_circuit_or_recover()
        if self._parallel_tabs:
            port, key = resolve_mutation_lock(self._driver, True)
        else:
            port, key = self._cdp_port, None
        async with MutationLock(port, key):
            if self._parallel_tabs:
                _, current_key = resolve_mutation_lock(self._driver, True)
                if current_key != key:
                    raise OwnedTabRequiredError(
                        "owned target changed while waiting for mutation lock"
                    )
            await self._check_circuit_or_recover()
            yield

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
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url, allow_redirects=True) as upstream:
                    if upstream.status >= 400:
                        preview = (await upstream.text())[:300]
                        raise ParityBrowserError(
                            f"ChatGPT asset download failed ({upstream.status}): {preview}"
                        )
                    headers = {}
                    if content_type := upstream.headers.get("Content-Type"):
                        headers["Content-Type"] = content_type
                    file_name = metadata.get("file_name")
                    if file_name:
                        encoded = urllib.parse.quote(str(file_name), safe="")
                        headers["Content-Disposition"] = (
                            f"inline; filename*=UTF-8''{encoded}"
                        )
                    response = web.StreamResponse(status=200, headers=headers)
                    await response.prepare(request)
                    async for chunk in upstream.content.iter_chunked(1024 * 1024):
                        await response.write(chunk)
                    await response.write_eof()
                    return response
        except Exception as exc:
            return self._parity_error(exc)


def _optional_string(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _json_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError:
            return {}
        return decoded if isinstance(decoded, dict) else {}
    return {}


def _mode_has_background_tasks(mode: str) -> bool:
    clean = mode.strip().lower().replace("-", "_").replace(" ", "_")
    return clean in {"deep_research", "image"}


def _filter_tasks(data: Any, conversation_id: str) -> Any:
    if isinstance(data, dict):
        for key in ("items", "tasks", "data"):
            items = data.get(key)
            if isinstance(items, list):
                copied = dict(data)
                copied[key] = [
                    item
                    for item in items
                    if not isinstance(item, dict)
                    or str(item.get("conversation_id") or "") == conversation_id
                ]
                return copied
    if isinstance(data, list):
        return [
            item
            for item in data
            if not isinstance(item, dict)
            or str(item.get("conversation_id") or "") == conversation_id
        ]
    return data
