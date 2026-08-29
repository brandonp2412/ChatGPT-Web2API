"""Client-safe projection of ChatGPT's full conversation tree."""

from __future__ import annotations

from typing import Any

from .parity_models import normalize_conversation, normalize_message


def normalize_client_conversation(raw: dict[str, Any]) -> dict[str, Any]:
    """Normalize active transcript plus every visible alternate branch node.

    ChatGPT conversations are trees. The normal transcript follows
    ``current_node`` back to the root, but regenerate/edit can create siblings
    that the UI lets the user page between. Those sibling messages must be
    available to a native client without exposing visually-hidden context or
    internal reasoning payloads.
    """
    data = normalize_conversation(raw)
    data["messages"] = [
        message
        for message in data.get("messages", [])
        if isinstance(message, dict) and not message.get("hidden", False)
    ]

    mapping = raw.get("mapping")
    if not isinstance(mapping, dict):
        data["nodes"] = {}
        return data

    nodes: dict[str, dict[str, Any]] = {}
    for node_id, value in mapping.items():
        if not isinstance(node_id, str) or not isinstance(value, dict):
            continue
        raw_message = value.get("message")
        message = None
        if isinstance(raw_message, dict):
            normalized = normalize_message(
                raw_message,
                node_id=node_id,
                node=value,
            )
            if normalized is not None and not normalized.get("hidden", False):
                message = normalized
        nodes[node_id] = {
            "id": node_id,
            "parent": value.get("parent"),
            "children": [
                str(item)
                for item in value.get("children", [])
                if item is not None
            ]
            if isinstance(value.get("children"), list)
            else [],
            "message": message,
        }

    data["nodes"] = nodes
    return data
