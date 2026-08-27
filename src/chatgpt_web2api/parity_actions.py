"""Parity operations that sit above raw conversation reads.

Reads use ChatGPT's authenticated backend endpoints from the logged-in page.
Mutations that create model output (edit/regenerate/branch) are intentionally
triggered through the SPA so ChatGPT itself owns Sentinel/proof-of-work and the
exact request shape.
"""

from __future__ import annotations

import asyncio
import json
import time
import urllib.parse
from typing import Any

from .parity_browser import ParityBrowserError
from .parity_models import normalize_conversation


class ParityActions:
    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def search_conversations(
        self,
        query: str,
        *,
        cursor: str | None = None,
    ) -> dict[str, Any]:
        token = await self.driver.ensure_token()
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const p = new URLSearchParams({query: __D.query});
              if (__D.cursor) p.set('cursor', __D.cursor);
              const r = await fetch('/backend-api/conversations/search?' + p.toString(), {
                credentials:'include',
                headers:{'Authorization':'Bearer ' + __D.token}
              });
              const text = await r.text();
              let data = {}; try { data = JSON.parse(text); } catch (_) { data = {detail:text.slice(0,500)}; }
              return JSON.stringify({ok:r.ok,status:r.status,data});
            })()""",
            {"query": query, "cursor": cursor or "", "token": token},
            timeout=30,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT conversation search failed ({result.get('status')})"
            )
        data = result.get("data")
        return data if isinstance(data, dict) else {"items": []}

    async def asset_download_url(
        self,
        asset_pointer: str,
        *,
        conversation_id: str | None = None,
        inline: bool = False,
    ) -> dict[str, Any]:
        """Resolve a ChatGPT file/sediment pointer to a signed download URL."""
        file_id, sediment = _asset_id(asset_pointer)
        token = await self.driver.ensure_token()
        if sediment:
            if not conversation_id:
                raise ParityBrowserError("conversation_id is required for sediment assets")
            path = (
                f"/backend-api/files/download/{urllib.parse.quote(file_id, safe='')}"
                f"?conversation_id={urllib.parse.quote(conversation_id, safe='')}"
                f"&inline={'true' if inline else 'false'}"
            )
        else:
            path = f"/backend-api/files/{urllib.parse.quote(file_id, safe='')}/download"
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const r = await fetch(__D.path, {
                credentials:'include', headers:{'Authorization':'Bearer ' + __D.token}
              });
              const text = await r.text();
              let data = {}; try { data = JSON.parse(text); } catch (_) { data = {detail:text.slice(0,500)}; }
              return JSON.stringify({ok:r.ok,status:r.status,data});
            })()""",
            {"path": path, "token": token},
            timeout=30,
        )
        result = _json_dict(raw)
        data = result.get("data") if isinstance(result.get("data"), dict) else {}
        if not result.get("ok") or not data.get("download_url"):
            raise ParityBrowserError(f"ChatGPT asset resolution failed ({result.get('status')})")
        return data

    async def trigger_message_action(
        self,
        action: str,
        *,
        conversation_id: str,
        message_id: str | None = None,
        message_text: str | None = None,
        replacement_text: str | None = None,
    ) -> dict[str, Any]:
        """Trigger edit/regenerate/branch using ChatGPT's own message controls."""
        clean = action.strip().lower().replace("-", "_").replace(" ", "_")
        if clean not in {"regenerate", "edit", "branch"}:
            raise ParityBrowserError(f"Unsupported message action: {action}")
        await self.driver.navigate_conversation(conversation_id)

        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const norm = s => (s || '').toLowerCase().replace(/\\s+/g, ' ').trim();
              const visible = el => {
                const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
                return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden';
              };
              const label = el => norm([
                el.getAttribute('aria-label'), el.getAttribute('title'),
                el.getAttribute('data-testid'), el.innerText, el.textContent
              ].filter(Boolean).join(' '));
              const messages = [...document.querySelectorAll('[data-message-author-role]')];
              let target = null;
              if (__D.message_id) {
                target = document.querySelector('[data-message-id="' + CSS.escape(__D.message_id) + '"]') ||
                         document.querySelector('[data-testid*="' + CSS.escape(__D.message_id) + '"]');
              }
              if (!target && __D.message_text) {
                const needle = norm(__D.message_text).slice(0, 160);
                target = messages.find(el => norm(el.innerText).includes(needle));
              }
              if (!target) {
                const role = __D.action === 'edit' ? 'user' : 'assistant';
                const byRole = messages.filter(el => el.getAttribute('data-message-author-role') === role);
                target = byRole[byRole.length - 1] || null;
              }
              if (!target) return JSON.stringify({ok:false,stage:'target'});
              target.scrollIntoView({block:'center'});
              target.dispatchEvent(new MouseEvent('mouseenter', {bubbles:true}));
              await new Promise(r => setTimeout(r, 250));

              const actionLabels = {
                regenerate:['regenerate','try again'],
                edit:['edit message','edit'],
                branch:['branch in new chat','branch']
              }[__D.action];
              const findAction = root => [...root.querySelectorAll('button,[role="menuitem"],[role="button"]')]
                .find(el => visible(el) && actionLabels.some(x => label(el).includes(x)));
              let button = findAction(target) || findAction(document);
              if (!button) {
                const more = [...target.querySelectorAll('button,[role="button"]')]
                  .find(el => visible(el) && /more|actions|menu/.test(label(el)));
                if (more) {
                  more.click(); await new Promise(r => setTimeout(r, 300));
                  button = findAction(document);
                }
              }
              if (!button) return JSON.stringify({ok:false,stage:'action'});
              button.click();

              if (__D.action === 'edit') {
                await new Promise(r => setTimeout(r, 300));
                const editor = target.querySelector('textarea,[contenteditable="true"]') ||
                  [...document.querySelectorAll('textarea,[contenteditable="true"]')].find(visible);
                if (!editor) return JSON.stringify({ok:false,stage:'editor'});
                editor.focus();
                if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) {
                  const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), 'value')?.set;
                  if (setter) setter.call(editor, __D.replacement_text); else editor.value = __D.replacement_text;
                  editor.dispatchEvent(new Event('input', {bubbles:true}));
                } else {
                  const selection = window.getSelection(); const range = document.createRange();
                  range.selectNodeContents(editor); selection.removeAllRanges(); selection.addRange(range);
                  document.execCommand('insertText', false, __D.replacement_text);
                  editor.dispatchEvent(new InputEvent('input', {bubbles:true,inputType:'insertText',data:__D.replacement_text}));
                }
                await new Promise(r => setTimeout(r, 150));
                const send = [...target.querySelectorAll('button')].find(el => visible(el) && /send|save|submit/.test(label(el))) ||
                  [...document.querySelectorAll('button')].find(el => visible(el) && /send|save/.test(label(el)));
                if (!send) return JSON.stringify({ok:false,stage:'edit_submit'});
                send.click();
              }
              return JSON.stringify({ok:true,stage:'triggered'});
            })()""",
            {
                "action": clean,
                "message_id": message_id or "",
                "message_text": message_text or "",
                "replacement_text": replacement_text or "",
            },
            timeout=15,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT {clean} UI action failed at {result.get('stage', 'unknown')}"
            )
        return result

    async def wait_for_conversation_change(
        self,
        conversation_id: str,
        *,
        previous_current_node: str | None,
        timeout: float = 240,
    ) -> dict[str, Any]:
        """Wait for a message action to produce a new settled branch leaf."""
        deadline = time.monotonic() + max(1.0, timeout)
        last: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            raw = await self.driver.get_conversation(conversation_id)
            if raw:
                last = raw
                if raw.get("current_node") != previous_current_node:
                    normalized = normalize_conversation(raw)
                    messages = normalized.get("messages") or []
                    tail = messages[-1] if messages else {}
                    if _is_settled_message(tail):
                        return normalized
            await asyncio.sleep(0.75)
        if last and last.get("current_node") != previous_current_node:
            return normalize_conversation(last)
        raise ParityBrowserError("Timed out waiting for ChatGPT message action to settle")

    async def current_conversation_id_from_url(self) -> str | None:
        raw = await self.driver._js_strict("location.href", timeout=5)
        url = str(raw or "")
        try:
            parts = [part for part in urllib.parse.urlparse(url).path.split("/") if part]
        except ValueError:
            return None
        for index, part in enumerate(parts[:-1]):
            if part == "c":
                return parts[index + 1]
        return None


def _asset_id(pointer: str) -> tuple[str, bool]:
    clean = pointer.strip()
    sediment = clean.startswith("sediment://")
    for prefix in ("sediment://", "file-service://", "sandbox://"):
        if clean.startswith(prefix):
            clean = clean[len(prefix) :]
            break
    clean = clean.split("?", 1)[0].strip("/")
    if not clean:
        raise ParityBrowserError("Invalid asset pointer")
    return clean, sediment


def _is_settled_message(message: Any) -> bool:
    if not isinstance(message, dict):
        return False
    if message.get("end_turn") is True:
        return True
    return str(message.get("status") or "").lower() in {
        "finished_successfully",
        "complete",
        "completed",
    }


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
