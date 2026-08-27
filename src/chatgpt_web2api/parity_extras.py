"""Smaller ChatGPT chat-surface operations used by the parity REST API."""

from __future__ import annotations

import asyncio
import json
from typing import Any

from .parity_browser import ParityBrowserError


class ParityExtras:
    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def tasks(self) -> Any:
        return await self._backend_json("GET", "/backend-api/tasks")

    async def pins(self) -> Any:
        return await self._backend_json("GET", "/backend-api/pins")

    async def feedback(
        self,
        *,
        conversation_id: str,
        message_id: str,
        rating: str,
        text: str | None = None,
        tags: list[str] | None = None,
    ) -> Any:
        clean = rating.strip()
        if clean not in {"thumbsUp", "thumbsDown"}:
            raise ParityBrowserError("rating must be thumbsUp or thumbsDown")
        body: dict[str, Any] = {
            "conversation_id": conversation_id,
            "message_id": message_id,
            "rating": clean,
        }
        if text is not None:
            body["text"] = text
        if tags is not None:
            body["tags"] = tags
        return await self._backend_json(
            "POST", "/backend-api/conversation/message_feedback", body
        )

    async def create_share(
        self,
        *,
        conversation_id: str,
        current_node_id: str,
        anonymous: bool = True,
    ) -> dict[str, Any]:
        """Create/publish a ChatGPT share link using the logged-in browser."""
        created = await self._backend_json(
            "POST",
            "/backend-api/share/create",
            {
                "conversation_id": conversation_id,
                "current_node_id": current_node_id,
                "is_anonymous": anonymous,
            },
        )
        if not isinstance(created, dict):
            raise ParityBrowserError("ChatGPT share create returned invalid data")
        share_id = created.get("share_id") or created.get("id")
        if not share_id:
            raise ParityBrowserError("ChatGPT share create returned no share ID")

        # Historically creation made the snapshot but publication happened on
        # the next PATCH. Newer deployments may return an already-public link;
        # PATCH only when the response indicates it is not public yet.
        if created.get("is_public") is not True:
            patch_body = {
                "highlighted_message_id": created.get("highlighted_message_id"),
                "is_anonymous": anonymous,
                "is_public": True,
                "is_visible": True,
                "share_id": share_id,
                "title": created.get("title") or "Shared conversation",
            }
            try:
                await self._backend_json(
                    "PATCH",
                    f"/backend-api/share/{conversation_id}",
                    patch_body,
                )
                created["is_public"] = True
            except ParityBrowserError:
                # The share API has changed path shape before. If creation
                # already returned a share_url, keep it usable instead of
                # destroying a successfully-created snapshot.
                if not created.get("share_url"):
                    raise
        if not created.get("share_url"):
            created["share_url"] = f"https://chatgpt.com/share/{share_id}"
        return created

    async def delete_share(self, share_id: str) -> bool:
        await self._backend_json("DELETE", f"/backend-api/share/{share_id}")
        return True

    async def set_pin(self, conversation_id: str, pinned: bool) -> bool:
        """Pin/unpin through the web UI because the mutation endpoint drifts."""
        await self.driver.navigate_conversation(conversation_id)
        aliases = ["pin chat", "pin conversation"] if pinned else ["unpin chat", "unpin conversation"]
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const norm = s => (s || '').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible = el => { const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'; };
              const label = el => norm([el.innerText,el.textContent,el.getAttribute('aria-label'),
                el.getAttribute('title'),el.getAttribute('data-testid')].filter(Boolean).join(' '));
              const controls = () => [...document.querySelectorAll(
                'button,[role="menuitem"],[role="button"],[data-testid]'
              )].filter(visible);
              const match = () => controls().find(el => __D.aliases.some(a => label(el).includes(a)));
              let target = match();
              if (!target) {
                const more = controls().find(el => /more|chat actions|conversation actions|menu/.test(label(el)));
                if (more) { more.click(); await new Promise(r => setTimeout(r,300)); target = match(); }
              }
              if (!target) return JSON.stringify({ok:false});
              target.click(); return JSON.stringify({ok:true,label:label(target)});
            })()""",
            {"aliases": aliases},
            timeout=10,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT does not currently expose {'Pin' if pinned else 'Unpin'} chat"
            )
        await asyncio.sleep(0.35)
        return True

    async def _backend_json(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
    ) -> Any:
        token = await self.driver.ensure_token()
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const init = {
                method:__D.method, credentials:'include',
                headers:{'Authorization':'Bearer ' + __D.token}
              };
              if (__D.has_body) {
                init.headers['Content-Type'] = 'application/json';
                init.body = JSON.stringify(__D.body);
              }
              const r = await fetch(__D.path, init);
              const text = await r.text();
              let data = null;
              if (text) { try { data = JSON.parse(text); } catch (_) { data = {text:text.slice(0,1000)}; } }
              return JSON.stringify({ok:r.ok,status:r.status,data});
            })()""",
            {
                "method": method,
                "path": path,
                "body": body or {},
                "has_body": body is not None,
                "token": token,
            },
            timeout=30,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            detail = result.get("data")
            raise ParityBrowserError(
                f"ChatGPT backend {method} {path} failed ({result.get('status')}): {detail}"
            )
        return result.get("data")


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
