"""Privacy boundary for the native ChatGPT client API."""

from __future__ import annotations

from typing import Any

from aiohttp import web

from .parity_browser import StoredAttachment
from .parity_policy_api import PolicyParityAPIServer
from .parity_secure_api import _client_view


class PrivacyParityAPIServer(PolicyParityAPIServer):
    """Final API: never exposes raw hidden ChatGPT conversation internals."""

    async def _handle_conversation(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        if request.query.get("raw") == "1":
            return web.json_response(
                {
                    "error": {
                        "message": (
                            "Raw ChatGPT conversation payloads are intentionally "
                            "disabled; use the normalized conversation tree"
                        ),
                        "type": "privacy_boundary",
                    }
                },
                status=400,
            )
        try:
            raw = await self._rich_conversation.fetch(
                request.match_info["conversation_id"]
            )
            if not raw:
                return web.json_response(
                    {"error": {"message": "Conversation not found"}},
                    status=404,
                )
            return web.json_response(
                {"object": "conversation", "data": _client_view(raw)}
            )
        except Exception as exc:
            return self._parity_error(exc)

    async def _execute_rich_send(
        self,
        request: web.Request,
        body: dict[str, Any],
        prompt: str,
        attachments: list[StoredAttachment],
    ) -> web.Response:
        mode = str(body.get("mode") or "normal").strip().lower().replace("-", "_")
        if mode == "canvas":
            return self._bad_request(
                "Canvas mode is deprecated; use normal chat writing/code blocks"
            )
        return await super()._execute_rich_send(
            request,
            body,
            prompt,
            attachments,
        )

    async def _handle_capabilities(self, request: web.Request) -> web.Response:
        if err := self._check_auth(request):
            return err
        return web.json_response(
            {
                "schema": "chatgpt-parity.v1",
                "conversation_tree": True,
                "alternate_response_branches": True,
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
                    "report_recovery": True,
                },
                "study": True,
                "data_analysis": True,
                "voice": {"enabled": True, "files": True, "projects": True},
                "projects": {
                    "enabled": True,
                    "conversation_feed": True,
                    "files": True,
                },
                "custom_gpts": True,
                "memory": True,
                "apps": True,
                "temporary_chat": True,
                "pins": True,
                "share": True,
                "feedback": True,
                "reasoning_levels": True,
                "writing_blocks": True,
                "code_blocks": {"edit": True, "preview": True, "run": True},
                "canvas": False,
                "raw_hidden_conversation": False,
                "message_actions": {
                    "edit": True,
                    "regenerate": True,
                    "branch": True,
                    "branch_select": True,
                    "copy": "client_side",
                    "read_aloud": "client_side_or_voice",
                },
                "dynamic_tools_url": "/v1/tools",
                "reasoning_levels_url": "/v1/reasoning-levels",
                "library_url": "/v1/library",
                "ui_actions_url": "/v1/ui-actions",
                "background_tasks_url": "/v1/tasks",
                "streaming": "sse",
                "background_events": "sse",
                "transport": "chatgpt-spa-cdp",
            }
        )
