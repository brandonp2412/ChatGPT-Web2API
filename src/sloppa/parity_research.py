"""Deep Research widget-state recovery for the client-visible conversation."""

from __future__ import annotations

import json
import urllib.parse
from typing import Any

from .parity_models import extract_assets, extract_citations


class RichConversationController:
    """Fetch conversation data including connector widget state when supported."""

    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def fetch(self, conversation_id: str) -> dict[str, Any]:
        token = await self.driver.ensure_token()
        conversation = urllib.parse.quote(conversation_id, safe="")
        path = (
            f"/backend-api/conversation/{conversation}"
            "?include_widget_state=true"
        )
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const r=await fetch(__D.path,{
                credentials:'include',headers:{'Authorization':'Bearer '+__D.token}
              });
              const text=await r.text();let data=null;
              if(text){try{data=JSON.parse(text);}catch(_){} }
              return JSON.stringify({ok:r.ok,status:r.status,data});
            })()""",
            {"path": path, "token": token},
            timeout=30,
        )
        result = _json_dict(raw)
        data = result.get("data")
        if result.get("ok") and isinstance(data, dict):
            return data
        # Older/rolled-back deployments may not understand the query flag.
        fallback = await self.driver.get_conversation(conversation_id)
        return fallback if isinstance(fallback, dict) else {}


def extract_research_reports(raw: Any) -> list[dict[str, Any]]:
    """Extract visible report payloads without returning raw connector state."""
    found: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    def visit(value: Any, key: str | None = None) -> None:
        if isinstance(value, dict):
            if key == "report_message":
                report = _normalize_report(value)
                if report:
                    identity = (
                        str(report.get("id") or ""),
                        str(report.get("text") or "")[:200],
                    )
                    if identity not in seen:
                        seen.add(identity)
                        found.append(report)
                return
            for child_key, child in value.items():
                visit(child, str(child_key))
        elif isinstance(value, list):
            for child in value:
                visit(child, key)

    visit(raw)
    return found


def _normalize_report(value: dict[str, Any]) -> dict[str, Any] | None:
    text = _report_text(value)
    citations = extract_citations(value)
    assets = extract_assets(value)
    if not text and not citations and not assets:
        return None
    return {
        "id": value.get("id") or value.get("message_id"),
        "type": "research_report",
        "text": text,
        "citations": citations,
        "assets": assets,
        "status": value.get("status"),
        "create_time": value.get("create_time") or value.get("created_at"),
        "update_time": value.get("update_time") or value.get("updated_at"),
    }


def _report_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = [_report_text(item) for item in value]
        return "\n".join(part for part in parts if part)
    if not isinstance(value, dict):
        return ""

    for key in ("text", "report", "markdown"):
        direct = value.get(key)
        if isinstance(direct, str) and direct:
            return direct

    content = value.get("content")
    if isinstance(content, dict):
        parts = content.get("parts")
        if isinstance(parts, list):
            text_parts = [part for part in parts if isinstance(part, str) and part]
            if text_parts:
                return "\n".join(text_parts)
        nested = _report_text(content)
        if nested:
            return nested
    elif isinstance(content, str) and content:
        return content

    message = value.get("message")
    if message is not None:
        return _report_text(message)
    return ""


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
