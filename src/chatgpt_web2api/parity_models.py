"""Stable structured representation of ChatGPT conversation trees.

The web conversation API is a tree, not a flat transcript. The Flutter client
needs the selected branch for normal rendering *and* enough tree information to
implement regenerate/edit/branch without throwing away ChatGPT metadata.

Keep this module pure: it deliberately knows nothing about CDP or aiohttp so it
is cheap to unit-test whenever ChatGPT changes its response shape.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any


_IMAGE_MIME_PREFIX = "image/"
_ASSET_POINTER_PREFIXES = ("sediment://", "file-service://", "sandbox://")
_CITATION_KEYS = {
    "citations",
    "content_references",
    "contentReferences",
    "search_results",
    "search_result_groups",
    "web_results",
    "references",
}
_VISIBLE_REASONING_TYPES = {"reasoning_recap", "reasoning_summary"}
_INTERNAL_REASONING_TYPES = {"thoughts", "chain_of_thought", "reasoning"}
_HIDDEN_CONTEXT_TYPES = {
    "model_editable_context",
    "user_editable_context",
    "system_error",
}


def normalize_conversation(raw: dict[str, Any]) -> dict[str, Any]:
    """Return a client-facing conversation while preserving branch semantics."""
    mapping = _as_dict(raw.get("mapping"))
    current_node = _string(raw.get("current_node")) or None
    branch_ids = current_branch_ids(mapping, current_node)
    messages = []
    for node_id in branch_ids:
        node = _as_dict(mapping.get(node_id))
        message = normalize_message(_as_dict(node.get("message")), node_id=node_id, node=node)
        if message is not None:
            messages.append(message)

    tree = {
        node_id: {
            "id": node_id,
            "parent": _string(node.get("parent")) or None,
            "children": [str(item) for item in _as_list(node.get("children")) if item],
            "message_id": _string(_as_dict(node.get("message")).get("id")) or None,
        }
        for node_id, value in mapping.items()
        if isinstance(node_id, str) and (node := _as_dict(value))
    }

    return {
        "id": _string(raw.get("conversation_id") or raw.get("id")),
        "title": _string(raw.get("title")) or "Untitled",
        "create_time": raw.get("create_time"),
        "update_time": raw.get("update_time"),
        "current_node": current_node,
        "messages": messages,
        "tree": tree,
        "default_model_slug": raw.get("default_model_slug"),
        "gizmo_id": raw.get("gizmo_id"),
        "is_archived": bool(raw.get("is_archived", False)),
    }


def current_branch_ids(mapping: dict[str, Any], current_node: str | None) -> list[str]:
    """Walk parent links from current_node to root, returning root -> leaf IDs."""
    if not current_node:
        return []
    ordered: list[str] = []
    seen: set[str] = set()
    node_id: str | None = current_node
    while node_id and node_id not in seen:
        seen.add(node_id)
        node = _as_dict(mapping.get(node_id))
        if not node:
            break
        ordered.append(node_id)
        node_id = _string(node.get("parent")) or None
    ordered.reverse()
    return ordered


def normalize_message(
    raw: dict[str, Any],
    *,
    node_id: str | None = None,
    node: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Normalize one ChatGPT message into typed, forward-compatible blocks.

    Unknown metadata is retained under ``metadata`` because tool/artifact
    schemas drift often. Raw hidden chain-of-thought content is never promoted
    into a client-visible block; visible reasoning recap/summary content is.
    """
    if not raw:
        return None
    author = _as_dict(raw.get("author"))
    role = _string(author.get("role"))
    if not role:
        return None

    content = _as_dict(raw.get("content"))
    metadata = _as_dict(raw.get("metadata"))
    content_type = _string(content.get("content_type"))
    author_name = _string(author.get("name")) or None
    blocks = content_blocks(
        content,
        metadata,
        role=role,
        author_name=author_name,
    )
    hidden = bool(metadata.get("is_visually_hidden_from_conversation")) or (
        content_type in _HIDDEN_CONTEXT_TYPES
    )

    result: dict[str, Any] = {
        "id": _string(raw.get("id")),
        "node_id": node_id,
        "parent": _string((node or {}).get("parent")) or None,
        "children": [str(item) for item in _as_list((node or {}).get("children")) if item],
        "role": role,
        "name": author_name,
        "create_time": raw.get("create_time"),
        "update_time": raw.get("update_time"),
        "status": raw.get("status"),
        "end_turn": raw.get("end_turn"),
        "recipient": raw.get("recipient"),
        "content_type": content_type or None,
        "blocks": blocks,
        "hidden": hidden,
        "metadata": metadata,
    }
    text = "\n".join(
        block["text"]
        for block in blocks
        if block.get("type") in {"text", "reasoning_recap"} and block.get("text")
    )
    if text:
        result["text"] = text
    return result


def content_blocks(
    content: dict[str, Any],
    metadata: dict[str, Any] | None = None,
    *,
    role: str | None = None,
    author_name: str | None = None,
) -> list[dict[str, Any]]:
    """Convert ChatGPT content/metadata into client-facing rich blocks."""
    metadata = metadata or {}
    content_type = _string(content.get("content_type"))
    blocks: list[dict[str, Any]] = []

    if content_type == "code":
        code = _content_text(content)
        if code:
            blocks.append(
                {
                    "type": "code",
                    "code": code,
                    "language": content.get("language") or metadata.get("language"),
                    "response_format_name": content.get("response_format_name"),
                    "tether_id": content.get("tether_id") or metadata.get("tether_id"),
                }
            )
    elif content_type == "execution_output":
        output = _string(content.get("result")) or _content_text(content)
        blocks.append(
            {
                "type": "execution_output",
                "text": output,
                "assets": extract_assets(content),
                "metadata": metadata,
            }
        )
    elif content_type in _VISIBLE_REASONING_TYPES:
        text = _content_text(content)
        if text:
            blocks.append({"type": "reasoning_recap", "text": text})
    elif content_type in _INTERNAL_REASONING_TYPES:
        # Product parity means matching the visible ChatGPT surface, not
        # exposing internal chain-of-thought that the product does not show.
        summary = _string(metadata.get("reasoning_summary") or metadata.get("summary"))
        if summary:
            blocks.append({"type": "reasoning_recap", "text": summary})
        else:
            blocks.append({"type": "reasoning_status", "available": True})
    elif content_type == "tether_browsing_display":
        blocks.append({"type": "web_result", "value": content, "metadata": metadata})
    elif content_type == "tether_quote":
        blocks.append(
            {
                "type": "quote",
                "text": _content_text(content),
                "url": content.get("url"),
                "title": content.get("title"),
                "domain": content.get("domain"),
            }
        )
    elif content_type not in _HIDDEN_CONTEXT_TYPES:
        _append_parts(blocks, content)

    # Some tool messages carry meaningful payload outside ``parts``.
    if not blocks and content_type not in _HIDDEN_CONTEXT_TYPES:
        text = _content_text(content)
        if text:
            blocks.append({"type": "text", "text": text})

    existing_assets = {
        block.get("asset_pointer") or block.get("file_id")
        for block in blocks
        if block.get("type") in {"image", "file"}
    }
    for asset in extract_assets({"content": content, "metadata": metadata}):
        identity = asset.get("asset_pointer") or asset.get("file_id")
        if identity and identity not in existing_assets:
            blocks.append(asset)
            existing_assets.add(identity)

    citations = extract_citations({"content": content, "metadata": metadata})
    if citations:
        blocks.append({"type": "citations", "items": citations})

    tool_name = _string(
        author_name
        or metadata.get("tool_name")
        or metadata.get("invoked_plugin")
        or metadata.get("plugin_name")
    )
    if role == "tool" or tool_name:
        blocks.append(
            {
                "type": "tool",
                "name": tool_name or "tool",
                "status": metadata.get("status"),
                "metadata": metadata,
            }
        )

    if (
        metadata.get("research_task_id")
        or metadata.get("deep_research")
        or (tool_name and "research" in tool_name.lower())
    ):
        blocks.append(
            {
                "type": "research",
                "task_id": metadata.get("research_task_id") or metadata.get("task_id"),
                "status": metadata.get("status"),
                "metadata": metadata,
            }
        )

    if _looks_like_editable_block(content, metadata):
        blocks.append(
            {
                "type": "editable_block",
                "block_kind": _editable_block_kind(content, metadata),
                "tether_id": content.get("tether_id") or metadata.get("tether_id"),
                "language": content.get("language") or metadata.get("language"),
                "metadata": metadata,
            }
        )

    return _dedupe_blocks(blocks)


def extract_citations(value: Any) -> list[dict[str, Any]]:
    """Extract citation-like records without assuming one ChatGPT schema version."""
    found: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()

    def visit(item: Any, key: str | None = None) -> None:
        if isinstance(item, dict):
            if key in _CITATION_KEYS or _looks_like_citation(item):
                candidate = _citation_record(item)
                if candidate:
                    identity = (
                        _string(candidate.get("url")),
                        _string(candidate.get("title")),
                        _string(candidate.get("text")),
                    )
                    if identity not in seen:
                        seen.add(identity)
                        found.append(candidate)
            for child_key, child in item.items():
                visit(child, str(child_key))
        elif isinstance(item, list):
            for child in item:
                visit(child, key)

    visit(value)
    return found


def extract_assets(value: Any) -> list[dict[str, Any]]:
    """Find file/image asset pointers recursively in content and metadata."""
    found: list[dict[str, Any]] = []
    seen: set[str] = set()

    def visit(item: Any) -> None:
        if isinstance(item, dict):
            pointer = _string(
                item.get("asset_pointer")
                or item.get("assetPointer")
                or item.get("file_id")
                or item.get("fileId")
            )
            url = _string(item.get("url") or item.get("download_url"))
            mime = _string(item.get("mime_type") or item.get("mimeType"))
            identity = pointer or url
            if identity and _is_asset_identity(identity, item):
                if identity not in seen:
                    seen.add(identity)
                    found.append(
                        {
                            "type": "image" if _is_image(item, mime, identity) else "file",
                            "asset_pointer": pointer or None,
                            "file_id": _string(item.get("file_id") or item.get("fileId")) or None,
                            "url": url or None,
                            "name": item.get("file_name") or item.get("name"),
                            "mime_type": mime or None,
                            "width": item.get("width"),
                            "height": item.get("height"),
                            "size": item.get("file_size") or item.get("file_size_bytes"),
                        }
                    )
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
        elif isinstance(item, str) and item.startswith(_ASSET_POINTER_PREFIXES):
            if item not in seen:
                seen.add(item)
                found.append({"type": "file", "asset_pointer": item})

    visit(value)
    return found


def _append_parts(blocks: list[dict[str, Any]], content: dict[str, Any]) -> None:
    content_type = _string(content.get("content_type"))
    for part in _as_list(content.get("parts")):
        if isinstance(part, str):
            if part:
                blocks.append({"type": "text", "text": part})
            continue
        if isinstance(part, dict):
            block = _part_to_block(part)
            if block:
                blocks.append(block)
    if not blocks and content_type == "multimodal_text":
        text = _string(content.get("text"))
        if text:
            blocks.append({"type": "text", "text": text})


def _part_to_block(part: dict[str, Any]) -> dict[str, Any] | None:
    kind = _string(part.get("content_type") or part.get("type") or part.get("kind"))
    if kind == "execution_output":
        return {
            "type": "execution_output",
            "text": _string(part.get("text") or part.get("result")),
            "value": part,
        }
    if kind == "code":
        return {
            "type": "code",
            "code": _string(part.get("text") or part.get("code")),
            "language": part.get("language"),
        }
    text = part.get("text")
    if isinstance(text, str) and text:
        return {"type": "text", "text": text}
    pointer = _string(part.get("asset_pointer") or part.get("assetPointer"))
    file_id = _string(part.get("file_id") or part.get("fileId"))
    mime = _string(part.get("mime_type") or part.get("mimeType"))
    url = _string(part.get("url") or part.get("download_url"))
    if pointer or file_id or url:
        return {
            "type": "image" if _is_image(part, mime, pointer or url) else "file",
            "asset_pointer": pointer or None,
            "file_id": file_id or None,
            "url": url or None,
            "name": part.get("file_name") or part.get("name"),
            "mime_type": mime or None,
            "width": part.get("width"),
            "height": part.get("height"),
            "size": part.get("file_size") or part.get("file_size_bytes"),
        }
    if kind:
        return {"type": "structured", "content_type": kind, "value": part}
    return None


def _content_text(content: dict[str, Any]) -> str:
    for key in ("text", "result", "summary"):
        value = content.get(key)
        if isinstance(value, str) and value:
            return value
    values = [part for part in _as_list(content.get("parts")) if isinstance(part, str) and part]
    return "\n".join(values)


def _looks_like_editable_block(content: dict[str, Any], metadata: dict[str, Any]) -> bool:
    content_type = _string(content.get("content_type")).lower()
    marker = " ".join(
        _string(value).lower()
        for value in (
            metadata.get("artifact_type"),
            metadata.get("block_type"),
            metadata.get("writing_block"),
            metadata.get("canvas_type"),
        )
        if value is not None
    )
    return bool(
        content.get("tether_id")
        or metadata.get("tether_id")
        or "writing" in marker
        or "canvas" in marker
        or content_type in {"code", "document"}
    )


def _editable_block_kind(content: dict[str, Any], metadata: dict[str, Any]) -> str:
    marker = " ".join(
        _string(value).lower()
        for value in (
            metadata.get("artifact_type"),
            metadata.get("block_type"),
            metadata.get("writing_block"),
            metadata.get("canvas_type"),
        )
        if value is not None
    )
    if "canvas" in marker:
        return "canvas"
    if "writing" in marker or "document" in marker:
        return "writing"
    if _string(content.get("content_type")) == "code":
        return "code"
    return "editable"


def _dedupe_blocks(blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for block in blocks:
        identity = (
            _string(block.get("type")),
            _string(block.get("asset_pointer") or block.get("file_id")),
            _string(block.get("text") or block.get("code") or block.get("name")),
        )
        if identity in seen and any(identity):
            continue
        seen.add(identity)
        result.append(block)
    return result


def _looks_like_citation(item: dict[str, Any]) -> bool:
    return bool(
        (item.get("url") or item.get("href"))
        and (item.get("title") or item.get("text") or item.get("snippet"))
    )


def _citation_record(item: dict[str, Any]) -> dict[str, Any] | None:
    url = item.get("url") or item.get("href")
    title = item.get("title") or item.get("name")
    text = item.get("text") or item.get("snippet") or item.get("attribution")
    if not any((url, title, text)):
        return None
    return {
        "url": url,
        "title": title,
        "text": text,
        "start_index": item.get("start_index") or item.get("startIndex"),
        "end_index": item.get("end_index") or item.get("endIndex"),
        "source": item.get("source") or item.get("domain"),
    }


def _is_asset_identity(identity: str, item: dict[str, Any]) -> bool:
    return identity.startswith(_ASSET_POINTER_PREFIXES) or bool(
        item.get("file_id")
        or item.get("fileId")
        or item.get("asset_pointer")
        or item.get("assetPointer")
        or item.get("mime_type")
        or item.get("mimeType")
    )


def _is_image(item: dict[str, Any], mime: str, identity: str) -> bool:
    if mime.startswith(_IMAGE_MIME_PREFIX):
        return True
    kind = _string(item.get("type") or item.get("content_type") or item.get("kind")).lower()
    if "image" in kind:
        return True
    lowered = identity.lower()
    return lowered.endswith((".png", ".jpg", ".jpeg", ".webp", ".gif"))


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    if isinstance(value, Iterable) and not isinstance(value, (str, bytes, dict)):
        return list(value)
    return []


def _string(value: Any) -> str:
    return value if isinstance(value, str) else "" if value is None else str(value)
