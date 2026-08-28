"""Privacy boundary for the native ChatGPT client API."""

from __future__ import annotations

import json
from typing import Any

from aiohttp import web

from .parity_browser import ParityBrowserError, StoredAttachment
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

    async def _handle_conversation_patch(self, request: web.Request) -> web.Response:
        response = await super()._handle_conversation_patch(request)
        return await self._sanitize_mutation_conversation(
            response,
            fallback_conversation_id=request.match_info["conversation_id"],
            field="data",
        )

    async def _handle_message_action(self, request: web.Request) -> web.Response:
        response = await super()._handle_message_action(request)
        return await self._sanitize_mutation_conversation(
            response,
            fallback_conversation_id=request.match_info["conversation_id"],
            field="data",
        )

    async def _handle_block_action(self, request: web.Request) -> web.Response:
        response = await super()._handle_block_action(request)
        return await self._sanitize_mutation_conversation(
            response,
            fallback_conversation_id=request.match_info["conversation_id"],
            field="conversation",
        )

    async def _sanitize_mutation_conversation(
        self,
        response: web.Response,
        *,
        fallback_conversation_id: str,
        field: str,
    ) -> web.Response:
        """Replace mutation snapshots with the same filtered view as GET.

        Several lower parity layers predate the final privacy boundary and
        return ``normalize_conversation(raw)`` after a mutation. That shape can
        retain visually-hidden/internal nodes. Responses have not been written
        to the network yet, so parse the in-memory response and replace only the
        conversation payload with a freshly fetched client-safe projection.
        Fail closed if the safe projection cannot be produced.
        """
        if response.status < 200 or response.status >= 300:
            return response
        try:
            body = response.body
            if not isinstance(body, (bytes, bytearray)):
                raise ParityBrowserError("Mutation response had no JSON body")
            payload = json.loads(bytes(body).decode("utf-8"))
            if not isinstance(payload, dict):
                raise ParityBrowserError("Mutation response was not an object")
            candidate = payload.get(field)
            conversation_id = fallback_conversation_id
            if isinstance(candidate, dict):
                conversation_id = str(
                    candidate.get("id")
                    or candidate.get("conversation_id")
                    or conversation_id
                )
            raw = await self._rich_conversation.fetch(conversation_id)
            if not raw:
                raise ParityBrowserError(
                    "Could not obtain privacy-filtered mutation snapshot"
                )
            payload[field] = _client_view(raw)
            return web.json_response(payload, status=response.status)
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
