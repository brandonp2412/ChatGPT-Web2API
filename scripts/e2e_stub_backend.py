from __future__ import annotations

import argparse
import asyncio
import json
from copy import deepcopy
from datetime import UTC, datetime
from typing import Any

from aiohttp import web


class StubState:
    def __init__(self) -> None:
        self.conversations: dict[str, dict[str, Any]] = {
            "conv-welcome": {
                "id": "conv-welcome",
                "title": "Welcome to Sloppa",
                "messages": [
                    {
                        "id": "m-user-1",
                        "role": "user",
                        "text": "Show me the deterministic E2E fixture.",
                    },
                    {
                        "id": "m-assistant-1",
                        "role": "assistant",
                        "text": "This conversation is served by the local Sloppa E2E bridge.",
                        "citations": [
                            {
                                "title": "Sloppa fixture",
                                "url": "https://example.com/sloppa-fixture",
                                "text": "Deterministic local fixture",
                            }
                        ],
                    },
                ],
                "nodes": {},
                "research_reports": [],
                "update_time": "2026-08-28T10:00:00Z",
            },
            "conv-markdown": {
                "id": "conv-markdown",
                "title": "Markdown and code",
                "messages": [
                    {
                        "id": "m-md-1",
                        "role": "assistant",
                        "text": "# Heading\n\n- one\n- two\n\n```dart\nprint('Sloppa');\n```",
                    }
                ],
                "nodes": {},
                "research_reports": [],
                "update_time": "2026-08-28T09:00:00Z",
            },
            "conv-assets": {
                "id": "conv-assets",
                "title": "Assets and report",
                "messages": [
                    {
                        "id": "m-asset-1",
                        "role": "assistant",
                        "text": "An attachment fixture follows.",
                        "assets": [
                            {
                                "file_name": "fixture.txt",
                                "mime_type": "text/plain",
                                "url": "https://example.com/fixture.txt",
                            }
                        ],
                    }
                ],
                "nodes": {},
                "research_reports": [
                    {
                        "id": "report-1",
                        "text": "A deterministic research report.",
                        "status": "complete",
                        "citations": [
                            {
                                "title": "Fixture source",
                                "url": "https://example.com/source",
                            }
                        ],
                    }
                ],
                "update_time": "2026-08-28T08:00:00Z",
            },
        }
        self.pins = {"conv-welcome"}
        self.memories = [
            {"id": "memory-1", "content": "Prefer concise deterministic fixtures."}
        ]
        self.projects = [
            {
                "id": "project-1",
                "name": "E2E Project",
                "instructions": "Use deterministic fixture data.",
                "memory_scope": "project_v2",
            }
        ]
        self.gpts = [
            {
                "id": "gpt-1",
                "name": "Fixture GPT",
                "description": "Local deterministic GPT fixture",
            }
        ]
        self.attachments: dict[str, dict[str, Any]] = {}
        self.next_id = 100

    def new_id(self, prefix: str) -> str:
        self.next_id += 1
        return f"{prefix}-{self.next_id}"

    def summary(self, conversation: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": conversation["id"],
            "title": conversation.get("title", "New chat"),
            "update_time": conversation.get("update_time")
            or datetime.now(UTC).isoformat(),
            "project_id": conversation.get("project_id"),
        }


@web.middleware
async def cors_middleware(request: web.Request, handler: Any) -> web.StreamResponse:
    if request.method == "OPTIONS":
        response: web.StreamResponse = web.Response(status=204)
    else:
        response = await handler(request)
    response.headers["Access-Control-Allow-Origin"] = request.headers.get("Origin", "*")
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,PATCH,DELETE,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Authorization,Content-Type,Accept"
    response.headers["Access-Control-Expose-Headers"] = "X-Request-Id"
    response.headers["Vary"] = "Origin"
    response.headers["X-Request-Id"] = "e2e-stub"
    return response


async def cors_prepare(request: web.Request, response: web.StreamResponse) -> None:
    """Apply CORS before streamed responses send their headers."""
    origin = request.headers.get("Origin", "*")
    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,PATCH,DELETE,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Authorization,Content-Type,Accept"
    response.headers["Access-Control-Expose-Headers"] = "X-Request-Id"
    response.headers["Vary"] = "Origin"


def json_response(data: Any, *, status: int = 200) -> web.Response:
    return web.json_response(data, status=status)


def create_app() -> web.Application:
    state = StubState()
    app = web.Application(middlewares=[cors_middleware])
    app.on_response_prepare.append(cors_prepare)
    app["state"] = state

    async def health(_: web.Request) -> web.Response:
        return json_response(
            {
                "status": "healthy",
                "ready_for_requests": True,
                "authenticated": True,
                "stub": True,
            }
        )

    async def capabilities(_: web.Request) -> web.Response:
        return json_response(
            {
                "data": {
                    "streaming": True,
                    "projects": True,
                    "gpts": True,
                    "attachments": True,
                }
            }
        )

    async def conversations(request: web.Request) -> web.Response:
        items = [state.summary(item) for item in state.conversations.values()]
        items.sort(key=lambda item: item["update_time"], reverse=True)
        offset = max(int(request.query.get("offset", "0")), 0)
        limit = min(max(int(request.query.get("limit", "50")), 1), 100)
        return json_response({"data": items[offset : offset + limit]})

    async def search_conversations(request: web.Request) -> web.Response:
        query = request.query.get("query", "").strip().casefold()
        items = [
            state.summary(item)
            for item in state.conversations.values()
            if query in item.get("title", "").casefold()
        ]
        return json_response({"data": items})

    async def get_conversation(request: web.Request) -> web.Response:
        conversation = state.conversations.get(request.match_info["conversation_id"])
        if conversation is None:
            return json_response(
                {"error": {"code": "not_found", "message": "Conversation not found"}},
                status=404,
            )
        return json_response({"data": deepcopy(conversation)})

    async def patch_conversation(request: web.Request) -> web.Response:
        conversation_id = request.match_info["conversation_id"]
        conversation = state.conversations.get(conversation_id)
        if conversation is None:
            return json_response(
                {"error": {"code": "not_found", "message": "Conversation not found"}},
                status=404,
            )
        body = await request.json()
        if "title" in body:
            conversation["title"] = str(body["title"]).strip() or "New chat"
        if "archived" in body:
            conversation["archived"] = bool(body["archived"])
        conversation["update_time"] = datetime.now(UTC).isoformat()
        return json_response({"data": deepcopy(conversation)})

    async def delete_conversation(request: web.Request) -> web.Response:
        conversation_id = request.match_info["conversation_id"]
        state.conversations.pop(conversation_id, None)
        state.pins.discard(conversation_id)
        return json_response({})

    async def message_action(request: web.Request) -> web.Response:
        conversation_id = request.match_info["conversation_id"]
        conversation = state.conversations.get(conversation_id)
        if conversation is None:
            return json_response(
                {"error": {"code": "not_found", "message": "Conversation not found"}},
                status=404,
            )
        body = await request.json()
        action = str(body.get("action", ""))
        message_id = str(body.get("message_id", ""))
        if action == "edit":
            for message in conversation["messages"]:
                if message.get("id") == message_id:
                    message["text"] = str(body.get("text", ""))
                    break
        elif action == "regenerate":
            conversation["messages"].append(
                {
                    "id": state.new_id("assistant"),
                    "role": "assistant",
                    "text": "Regenerated fixture response.",
                }
            )
        elif action == "branch":
            new_id = state.new_id("conv-branch")
            branched = deepcopy(conversation)
            branched["id"] = new_id
            branched["title"] = f"Branch of {conversation['title']}"
            state.conversations[new_id] = branched
            conversation = branched
        return json_response({"data": deepcopy(conversation)})

    async def models(_: web.Request) -> web.Response:
        return json_response(
            {"data": [{"id": "gpt-5.6"}, {"id": "gpt-5-mini"}]}
        )

    async def reasoning_levels(_: web.Request) -> web.Response:
        return json_response({"data": ["low", "medium", "high"]})

    async def tools(_: web.Request) -> web.Response:
        return json_response(
            {
                "data": [
                    {"label": "Search"},
                    {"label": "Image generation"},
                    {"label": "Deep research"},
                    {"label": "Study"},
                    {"label": "Calendar fixture"},
                ]
            }
        )

    async def projects(_: web.Request) -> web.Response:
        return json_response({"data": deepcopy(state.projects)})

    async def project_conversations(request: web.Request) -> web.Response:
        project_id = request.match_info["project_id"]
        items = [
            state.summary(item)
            for item in state.conversations.values()
            if item.get("project_id") == project_id
        ]
        return json_response({"data": {"items": items, "next_cursor": None}})

    async def gpts(_: web.Request) -> web.Response:
        return json_response({"data": deepcopy(state.gpts)})

    async def library(_: web.Request) -> web.Response:
        return json_response(
            {
                "data": [
                    {"name": "fixture-notes.txt", "detail": "Local fixture"},
                    {"name": "fixture-plan.md", "detail": "Markdown fixture"},
                ]
            }
        )

    async def ui_actions(_: web.Request) -> web.Response:
        return json_response(
            {"data": [{"label": "Approve fixture", "testid": "approve-fixture"}]}
        )

    async def trigger_ui_action(_: web.Request) -> web.Response:
        return json_response({"data": {"ok": True}})

    async def upload_attachment(request: web.Request) -> web.Response:
        reader = await request.multipart()
        field = await reader.next()
        if field is None or field.name != "file":
            return json_response(
                {"error": {"code": "missing_file", "message": "file is required"}},
                status=400,
            )
        payload = await field.read(decode=False)
        attachment_id = state.new_id("attachment")
        item = {
            "id": attachment_id,
            "name": field.filename or "attachment",
            "size": len(payload),
            "mime_type": field.headers.get("Content-Type", "application/octet-stream"),
        }
        state.attachments[attachment_id] = item
        return json_response({"data": item})

    async def send_chat(request: web.Request) -> web.StreamResponse:
        body = await request.json()
        prompt = str(body.get("prompt", "")).strip()
        conversation_id = str(body.get("conversation_id", "")).strip()
        if not conversation_id:
            conversation_id = state.new_id("conv")
            state.conversations[conversation_id] = {
                "id": conversation_id,
                "title": prompt[:40] or "Attachment chat",
                "messages": [],
                "nodes": {},
                "research_reports": [],
            }
        conversation = state.conversations[conversation_id]
        if prompt:
            conversation["messages"].append(
                {
                    "id": state.new_id("user"),
                    "role": "user",
                    "text": prompt,
                }
            )
        attachment_count = len(body.get("attachment_ids", []))
        library_count = len(body.get("library_files", []))
        response_text = "Stub reply"
        if prompt:
            response_text += f": {prompt}"
        if attachment_count:
            response_text += f" ({attachment_count} attachment(s))"
        if library_count:
            response_text += f" ({library_count} library file(s))"
        assistant = {
            "id": state.new_id("assistant"),
            "role": "assistant",
            "text": response_text,
        }
        conversation["messages"].append(assistant)
        conversation["update_time"] = datetime.now(UTC).isoformat()

        response = web.StreamResponse(
            status=200,
            headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"},
        )
        await response.prepare(request)
        midpoint = max(1, len(response_text) // 2)
        for delta in (response_text[:midpoint], response_text[midpoint:]):
            event = {"type": "message.delta", "text": delta, "conversation_id": conversation_id}
            await response.write(f"data: {json.dumps(event)}\n\n".encode())
            await asyncio.sleep(0.02)
        final_event = {
            "type": "conversation.updated",
            "conversation_id": conversation_id,
            "conversation": deepcopy(conversation),
        }
        await response.write(f"data: {json.dumps(final_event)}\n\n".encode())
        await response.write(b"data: [DONE]\n\n")
        await response.write_eof()
        return response

    async def background_events(request: web.Request) -> web.StreamResponse:
        conversation_id = request.match_info["conversation_id"]
        response = web.StreamResponse(
            status=200,
            headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"},
        )
        await response.prepare(request)
        conversation = state.conversations.get(conversation_id)
        if conversation is not None:
            event = {
                "type": "conversation.updated",
                "conversation_id": conversation_id,
                "conversation": deepcopy(conversation),
            }
            await response.write(f"data: {json.dumps(event)}\n\n".encode())
        await response.write(b"data: [DONE]\n\n")
        await response.write_eof()
        return response

    async def stop(_: web.Request) -> web.Response:
        return json_response({"data": {"stopped": True}})

    async def select_branch(request: web.Request) -> web.Response:
        conversation = state.conversations.get(request.match_info["conversation_id"])
        return json_response({"conversation": deepcopy(conversation) if conversation else None})

    async def block_action(request: web.Request) -> web.Response:
        conversation = state.conversations.get(request.match_info["conversation_id"])
        if conversation is None:
            return json_response(
                {"error": {"code": "not_found", "message": "Conversation not found"}},
                status=404,
            )
        return json_response({"conversation": deepcopy(conversation)})

    async def pins(_: web.Request) -> web.Response:
        return json_response(
            {"data": [{"conversation_id": item} for item in sorted(state.pins)]}
        )

    async def set_pin(request: web.Request) -> web.Response:
        conversation_id = request.match_info["conversation_id"]
        body = await request.json()
        if bool(body.get("pinned")):
            state.pins.add(conversation_id)
        else:
            state.pins.discard(conversation_id)
        return json_response({"data": {"conversation_id": conversation_id}})

    async def feedback(_: web.Request) -> web.Response:
        return json_response({"data": {"ok": True}})

    async def share(request: web.Request) -> web.Response:
        conversation_id = request.match_info["conversation_id"]
        share_id = state.new_id("share")
        return json_response(
            {
                "data": {
                    "id": share_id,
                    "url": f"https://example.com/share/{conversation_id}/{share_id}",
                }
            }
        )

    async def delete_share(_: web.Request) -> web.Response:
        return json_response({})

    async def memories(_: web.Request) -> web.Response:
        return json_response({"data": deepcopy(state.memories)})

    async def create_memory(request: web.Request) -> web.Response:
        body = await request.json()
        item = {"id": state.new_id("memory"), "content": str(body.get("content", ""))}
        state.memories.append(item)
        return json_response({"data": item})

    async def delete_memory(request: web.Request) -> web.Response:
        memory_id = request.match_info["memory_id"]
        state.memories = [item for item in state.memories if item["id"] != memory_id]
        return json_response({})

    async def create_project(request: web.Request) -> web.Response:
        body = await request.json()
        item = {
            "id": state.new_id("project"),
            "name": str(body.get("name", "Project")),
            "instructions": str(body.get("instructions", "")),
            "memory_scope": str(body.get("memory_scope", "project_v2")),
        }
        state.projects.insert(0, item)
        return json_response({"data": item})

    async def patch_project(request: web.Request) -> web.Response:
        project_id = request.match_info["project_id"]
        body = await request.json()
        project = next((item for item in state.projects if item["id"] == project_id), None)
        if project is None:
            return json_response(
                {"error": {"code": "not_found", "message": "Project not found"}},
                status=404,
            )
        if "instructions" in body:
            project["instructions"] = str(body["instructions"])
        if "name" in body:
            project["name"] = str(body["name"])
        return json_response({"data": deepcopy(project)})

    async def delete_project(request: web.Request) -> web.Response:
        project_id = request.match_info["project_id"]
        state.projects = [item for item in state.projects if item["id"] != project_id]
        return json_response({})

    async def project_files(_: web.Request) -> web.Response:
        return json_response(
            {
                "data": [
                    {
                        "id": "project-file-1",
                        "name": "fixture-project.txt",
                        "mime_type": "text/plain",
                        "size": 16,
                    }
                ]
            }
        )

    async def project_file_download(_: web.Request) -> web.Response:
        return web.Response(body=b"fixture project\n", content_type="text/plain")

    app.router.add_route("OPTIONS", "/{tail:.*}", lambda _: web.Response(status=204))
    app.router.add_get("/health", health)
    app.router.add_get("/v1/capabilities", capabilities)
    app.router.add_get("/v1/conversations", conversations)
    app.router.add_get("/v1/conversations/search", search_conversations)
    app.router.add_get("/v1/conversations/{conversation_id}", get_conversation)
    app.router.add_patch("/v1/conversations/{conversation_id}", patch_conversation)
    app.router.add_delete("/v1/conversations/{conversation_id}", delete_conversation)
    app.router.add_post("/v1/conversations/{conversation_id}/actions", message_action)
    app.router.add_get("/v1/models", models)
    app.router.add_get("/v1/reasoning-levels", reasoning_levels)
    app.router.add_get("/v1/tools", tools)
    app.router.add_get("/v1/projects", projects)
    app.router.add_post("/v1/projects", create_project)
    app.router.add_get("/v1/projects/{project_id}/conversations", project_conversations)
    app.router.add_patch("/v1/projects/{project_id}", patch_project)
    app.router.add_delete("/v1/projects/{project_id}", delete_project)
    app.router.add_get("/v1/projects/{project_id}/files", project_files)
    app.router.add_get(
        "/v1/projects/{project_id}/files/{file_id}/download", project_file_download
    )
    app.router.add_get("/v1/gpts", gpts)
    app.router.add_get("/v1/library", library)
    app.router.add_get("/v1/ui-actions", ui_actions)
    app.router.add_post("/v1/ui-actions", trigger_ui_action)
    app.router.add_post("/v1/attachments", upload_attachment)
    app.router.add_post("/v1/chat/send", send_chat)
    app.router.add_post("/v1/chat/stop", stop)
    app.router.add_get(
        "/v1/conversations/{conversation_id}/events", background_events
    )
    app.router.add_post(
        "/v1/conversations/{conversation_id}/branch/select", select_branch
    )
    app.router.add_post(
        "/v1/conversations/{conversation_id}/blocks/{message_id}/actions", block_action
    )
    app.router.add_get("/v1/pins", pins)
    app.router.add_patch("/v1/conversations/{conversation_id}/pin", set_pin)
    app.router.add_post("/v1/conversations/{conversation_id}/feedback", feedback)
    app.router.add_post("/v1/conversations/{conversation_id}/share", share)
    app.router.add_delete("/v1/shares/{share_id}", delete_share)
    app.router.add_get("/v1/memories", memories)
    app.router.add_post("/v1/memories", create_memory)
    app.router.add_delete("/v1/memories/{memory_id}", delete_memory)
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="Deterministic Sloppa E2E bridge fixture")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    web.run_app(create_app(), host=args.host, port=args.port, print=None)


if __name__ == "__main__":
    main()
