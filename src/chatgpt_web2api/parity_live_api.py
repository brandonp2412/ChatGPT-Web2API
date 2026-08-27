"""Live background-event surface for long-running ChatGPT chat workflows."""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

from aiohttp import web

from .parity_current_api import CurrentParityAPIServer
from .parity_models import normalize_conversation


class LiveParityAPIServer(CurrentParityAPIServer):
    """Current parity API plus a resumable read-only conversation event stream."""

    def __init__(self, config, driver, breakers=None) -> None:
        super().__init__(config, driver, breakers=breakers)
        self.app.router.add_get(
            "/v1/conversations/{conversation_id}/events",
            self._handle_conversation_events,
        )

    async def _handle_conversation_events(
        self, request: web.Request
    ) -> web.StreamResponse:
        """Stream snapshots/task progress after background or interactive work.

        This endpoint performs only authenticated reads. It deliberately does
        not acquire the mutation lock, because holding that lock would prevent
        the very ChatGPT generation/research operation being observed.
        """
        if err := self._check_auth(request):
            return err
        conversation_id = request.match_info["conversation_id"]
        timeout = _bounded_float(request.query.get("timeout"), 900.0, 1.0, 1800.0)
        interval = _bounded_float(request.query.get("interval"), 0.75, 0.25, 5.0)

        response = web.StreamResponse(
            headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            }
        )
        await response.prepare(request)

        deadline = time.monotonic() + timeout
        last_conversation_fingerprint = ""
        last_task_fingerprint = ""
        last_actions_fingerprint = ""
        last_heartbeat = 0.0

        try:
            while time.monotonic() < deadline:
                raw = await self._driver.get_conversation(conversation_id)
                if raw:
                    conversation = normalize_conversation(raw)
                    fingerprint = _fingerprint_conversation(conversation)
                    if fingerprint != last_conversation_fingerprint:
                        last_conversation_fingerprint = fingerprint
                        await _sse(
                            response,
                            {
                                "type": "conversation.snapshot",
                                "conversation_id": conversation_id,
                                "conversation": conversation,
                            },
                        )

                try:
                    tasks = await self._parity_extras.tasks()
                    task_view = _filter_tasks(tasks, conversation_id)
                    task_fingerprint = json.dumps(
                        task_view, sort_keys=True, default=str
                    )
                    if task_fingerprint != last_task_fingerprint:
                        last_task_fingerprint = task_fingerprint
                        await _sse(
                            response,
                            {
                                "type": "tool.progress",
                                "conversation_id": conversation_id,
                                "tasks": task_view,
                            },
                        )
                except Exception:
                    # Conversation updates remain useful even on accounts where
                    # the private task listing endpoint is absent/rolled back.
                    pass

                try:
                    current_id = (
                        await self._parity_actions.current_conversation_id_from_url()
                    )
                    if current_id == conversation_id:
                        actions = await self._ui_actions.list_actions()
                        action_fingerprint = json.dumps(
                            actions, sort_keys=True, default=str
                        )
                        if action_fingerprint != last_actions_fingerprint:
                            last_actions_fingerprint = action_fingerprint
                            await _sse(
                                response,
                                {
                                    "type": "ui.actions",
                                    "conversation_id": conversation_id,
                                    "actions": actions,
                                },
                            )
                except Exception:
                    pass

                now = time.monotonic()
                if now - last_heartbeat >= 15:
                    last_heartbeat = now
                    await _sse(
                        response,
                        {
                            "type": "heartbeat",
                            "conversation_id": conversation_id,
                        },
                    )
                await asyncio.sleep(interval)
        except (ConnectionResetError, asyncio.CancelledError):
            return response

        try:
            await _sse(
                response,
                {"type": "stream.timeout", "conversation_id": conversation_id},
            )
            await response.write(b"data: [DONE]\n\n")
            await response.write_eof()
        except ConnectionResetError:
            pass
        return response


def _fingerprint_conversation(conversation: dict[str, Any]) -> str:
    """Cheap stable signal for anything the visible active branch can render."""
    messages = conversation.get("messages") or []
    tail = messages[-1] if messages else {}
    return json.dumps(
        {
            "update_time": conversation.get("update_time"),
            "current_node": conversation.get("current_node"),
            "message_count": len(messages),
            "tail_id": tail.get("id") if isinstance(tail, dict) else None,
            "tail_status": tail.get("status") if isinstance(tail, dict) else None,
            "tail_end_turn": tail.get("end_turn") if isinstance(tail, dict) else None,
            "tail_blocks": tail.get("blocks") if isinstance(tail, dict) else None,
        },
        sort_keys=True,
        default=str,
    )


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


def _bounded_float(
    value: str | None,
    default: float,
    minimum: float,
    maximum: float,
) -> float:
    if value is None:
        return default
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    return min(maximum, max(minimum, parsed))


async def _sse(response: web.StreamResponse, data: dict[str, Any]) -> None:
    await response.write(
        f"data: {json.dumps(data, ensure_ascii=False)}\n\n".encode("utf-8")
    )
