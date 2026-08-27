"""Current ChatGPT chat-window API surface.

This is the final REST layer used by the service.  It keeps the older parity
layers intact while adding runtime-discovered controls that vary by account,
model and rollout: reasoning levels, Library attachments and intermediate
in-chat actions such as Deep Research plan approval.
"""

from __future__ import annotations

from typing import Any

from aiohttp import web

from .api_server import MODEL_MAP
from .parity_browser import ParityBrowserError, StoredAttachment
from .parity_current_controls import (
    LibraryController,
    ReasoningController,
    UIActionController,
)
from .parity_full_api import FullParityAPIServer


class CurrentParityAPIServer(FullParityAPIServer):
    """One backend exposing the current normal ChatGPT Chat experience."""

    def __init__(self, config, driver, breakers=None) -> None:
        self._reasoning = ReasoningController(driver)
        self._library = LibraryController(driver)
        self._ui_actions = UIActionController(driver)
        super().__init__(config, driver, breakers=breakers)

        self.app.router.add_get("/v1/reasoning-levels", self._handle_reasoning_levels)
        self.app.router.add_get("/v1/library", self._handle_library)
        self.app.router.add_get("/v1/ui-actions", self._handle_ui_actions)
        self.app.router.add_post("/v1/ui-actions", self._handle_ui_action)

    async def _handle_capabilities(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        return web.json_response(
            {
                "schema": "chatgpt-parity.v1",
                "conversation_tree": True,
                "conversation_search": True,
                "attachments": True,
                "library_attachments": True,
                "image_input": True,
                "image_generation": True,
                "image_edit": True,
                "search": True,
                "deep_research": {
                    "enabled": True,
                    "progress": True,
                    "interactive_plan": True,
                    "interrupt_and_refine": True,
                },
                "study": True,
                "data_analysis": True,
                "voice": {"enabled": True, "files": True, "projects": True},
                "projects": True,
                "custom_gpts": True,
                "memory": True,
                "plugins": True,
                "temporary_chat": True,
                "pins": True,
                "share": True,
                "feedback": True,
                "reasoning_levels": True,
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
                "reasoning_levels_url": "/v1/reasoning-levels",
                "library_url": "/v1/library",
                "ui_actions_url": "/v1/ui-actions",
                "background_tasks_url": "/v1/tasks",
                "streaming": "sse",
                "transport": "chatgpt-spa-cdp",
            }
        )

    async def _handle_reasoning_levels(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            async with self._mutation_guard():
                levels = await self._reasoning.available_levels()
            return web.json_response({"object": "list", "data": levels})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_library(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            async with self._mutation_guard():
                items = await self._library.list_items()
            return web.json_response({"object": "list", "data": items})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_ui_actions(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            conversation_id = request.query.get("conversation_id", "").strip()
            async with self._mutation_guard():
                if conversation_id:
                    await self._driver.navigate_conversation(conversation_id)
                actions = await self._ui_actions.list_actions()
            return web.json_response({"object": "list", "data": actions})
        except Exception as exc:
            return self._parity_error(exc)

    async def _handle_ui_action(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            label = _optional_string(body.get("label"))
            if not label:
                return self._bad_request("label is required")
            conversation_id = _optional_string(body.get("conversation_id"))
            async with self._mutation_guard():
                if conversation_id:
                    await self._driver.navigate_conversation(conversation_id)
                await self._ui_actions.trigger(label)
            return web.json_response({"triggered": True, "label": label})
        except Exception as exc:
            return self._parity_error(exc)

    async def _execute_rich_send(
        self,
        request: web.Request,
        body: dict[str, Any],
        prompt: str,
        attachments: list[StoredAttachment],
    ) -> web.Response:
        """Prepare the exact ChatGPT composer state, then submit through the SPA.

        Navigation deliberately happens before model/reasoning selection. A new
        chat navigation uses ``?model=auto`` for composer readiness, so selecting
        first would silently reset the requested model.
        """
        model = str(body.get("model") or self._config.chatgpt.default_model)
        model_slug = MODEL_MAP.get(model, model)
        conversation_id = _optional_string(body.get("conversation_id"))
        project_id = _optional_string(body.get("project_id"))
        gizmo_id = _optional_string(body.get("gizmo_id"))
        plugin = _optional_string(body.get("plugin"))
        reasoning_level = _optional_string(body.get("reasoning_level"))
        mode = _optional_string(body.get("mode")) or "normal"
        stream = body.get("stream", True) is not False
        timeout = self._send_timeout(body, mode)

        library_files_raw = body.get("library_files") or []
        if not isinstance(library_files_raw, list) or not all(
            isinstance(item, str) for item in library_files_raw
        ):
            return self._bad_request("library_files must be a list of strings")
        library_files = list(dict.fromkeys(item.strip() for item in library_files_raw if item.strip()))

        if conversation_id and body.get("temporary") is True:
            return self._bad_request(
                "Temporary Chat can only be selected when starting a new chat"
            )

        async with self._mutation_guard():
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

            if model_slug and model_slug != "auto":
                selected = await self._driver.select_model(model_slug)
                if not selected:
                    raise ParityBrowserError(
                        f"Requested model is not exposed by the current ChatGPT picker: {model}"
                    )

            if reasoning_level:
                await self._reasoning.set_level(reasoning_level)

            await self._parity_browser.select_tool(mode)
            if plugin:
                await self._parity_browser.select_plugin(plugin)
            if library_files:
                await self._library.attach_items(library_files)
            await self._parity_browser.attach_files(attachments)

            if stream:
                return await self._stream_rich_response(
                    request, model_slug, prompt, timeout, mode=mode
                )
            return await self._full_rich_response(
                model_slug, prompt, timeout, mode=mode
            )

    async def _handle_voice_session(self, request: web.Request) -> web.Response:
        """Negotiate Voice after applying optional conversation/project context."""
        if err := self._check_auth(request):
            return err
        try:
            body = await self._json_body(request)
            sdp = str(body.get("offer_sdp") or "")
            if not sdp:
                return self._bad_request("offer_sdp is required")
            conversation_id = _optional_string(body.get("conversation_id"))
            project_id = _optional_string(body.get("project_id"))
            async with self._mutation_guard():
                if conversation_id:
                    await self._driver.navigate_conversation(conversation_id)
                elif project_id:
                    await self._driver.navigate_new_chat(gizmo_id=project_id)
                result = await self._parity_browser.create_voice_session(
                    sdp,
                    voice=str(body.get("voice") or "cove"),
                    voice_mode=str(body.get("voice_mode") or "wingman"),
                    language_code=str(body.get("language_code") or "auto"),
                )
            return web.json_response(result)
        except Exception as exc:
            return self._parity_error(exc)


def _optional_string(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
