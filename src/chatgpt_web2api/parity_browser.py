"""Browser-backed primitives for ChatGPT chat-window feature parity.

The bridge deliberately lets the *real ChatGPT SPA* own fragile conversation
submission, Sentinel tokens, proof-of-work, file attachment state, and tool
selection.  This module only drives user-visible controls or calls authenticated
read/upload endpoints from the already logged-in page.
"""

from __future__ import annotations

import asyncio
import json
import logging
import mimetypes
import os
import re
import shutil
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import aiohttp

logger = logging.getLogger(__name__)

MAX_ATTACHMENT_BYTES = 512 * 1024 * 1024
_ATTACHMENT_TTL_SECONDS = 60 * 60


class ParityBrowserError(RuntimeError):
    """A ChatGPT browser feature could not be prepared safely."""


class AttachmentTooLargeError(ParityBrowserError):
    """Raised when a client upload exceeds the bridge's per-file hard limit."""


@dataclass(frozen=True, slots=True)
class StoredAttachment:
    id: str
    path: Path
    name: str
    mime_type: str
    size: int
    created_at: float

    def public_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "mime_type": self.mime_type,
            "size": self.size,
            "created_at": self.created_at,
        }


class AttachmentStore:
    """One-shot attachment staging with private filesystem permissions.

    Files exist only long enough for Chrome's file input to consume them.  They
    are never placed under the source tree and are deleted after send, explicit
    DELETE, TTL expiry, or server cleanup.
    """

    def __init__(self, *, max_bytes: int = MAX_ATTACHMENT_BYTES) -> None:
        self.max_bytes = max_bytes
        self.root = Path(tempfile.mkdtemp(prefix="chatgpt-web2api-attachments-"))
        try:
            self.root.chmod(0o700)
        except OSError:
            pass
        self._items: dict[str, StoredAttachment] = {}
        self._lock = asyncio.Lock()

    async def put_multipart_field(self, field: Any) -> StoredAttachment:
        """Stream an aiohttp multipart field to private temporary storage."""
        name = _safe_filename(getattr(field, "filename", None) or "attachment")
        mime_type = (
            getattr(field, "headers", {}).get("Content-Type")
            or mimetypes.guess_type(name)[0]
            or "application/octet-stream"
        )
        attachment_id = "att_" + uuid.uuid4().hex
        suffix = Path(name).suffix[:16]
        path = self.root / f"{attachment_id}{suffix}"
        size = 0
        try:
            with path.open("xb") as handle:
                try:
                    path.chmod(0o600)
                except OSError:
                    pass
                while True:
                    chunk = await field.read_chunk(size=1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > self.max_bytes:
                        raise AttachmentTooLargeError(
                            f"Attachment exceeds {self.max_bytes} byte limit"
                        )
                    handle.write(chunk)
        except Exception:
            path.unlink(missing_ok=True)
            raise

        item = StoredAttachment(
            id=attachment_id,
            path=path,
            name=name,
            mime_type=str(mime_type),
            size=size,
            created_at=time.time(),
        )
        async with self._lock:
            self._items[attachment_id] = item
        await self.prune()
        return item

    async def get_many(self, ids: list[str]) -> list[StoredAttachment]:
        await self.prune()
        async with self._lock:
            missing = [item_id for item_id in ids if item_id not in self._items]
            if missing:
                raise ParityBrowserError(f"Unknown or expired attachment: {missing[0]}")
            return [self._items[item_id] for item_id in ids]

    async def delete(self, attachment_id: str) -> bool:
        async with self._lock:
            item = self._items.pop(attachment_id, None)
        if item is None:
            return False
        item.path.unlink(missing_ok=True)
        return True

    async def delete_many(self, ids: list[str]) -> None:
        for attachment_id in ids:
            await self.delete(attachment_id)

    async def prune(self) -> None:
        cutoff = time.time() - _ATTACHMENT_TTL_SECONDS
        async with self._lock:
            stale = [key for key, item in self._items.items() if item.created_at < cutoff]
        for key in stale:
            await self.delete(key)

    async def close(self, _app: Any = None) -> None:
        async with self._lock:
            items = list(self._items.values())
            self._items.clear()
        for item in items:
            item.path.unlink(missing_ok=True)
        shutil.rmtree(self.root, ignore_errors=True)


class ParityBrowser:
    """High-level feature adapter over the bridge's existing CDPDriver."""

    TOOL_ALIASES: dict[str, tuple[str, ...]] = {
        "search": ("search", "search the web", "web search"),
        "image": ("create image", "create an image", "image generation"),
        "deep_research": ("deep research", "research"),
        "study": ("study and learn", "study"),
    }

    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def select_tool(self, mode: str | None) -> None:
        """Select a composer tool through the SPA, if one was requested."""
        clean = (mode or "normal").strip().lower().replace("-", "_").replace(" ", "_")
        if clean in {"", "normal", "chat", "auto"}:
            return
        aliases = self.TOOL_ALIASES.get(clean)
        if not aliases:
            raise ParityBrowserError(f"Unsupported composer mode: {mode}")

        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const norm = s => (s || '').toLowerCase().replace(/\\s+/g, ' ').trim();
              const aliases = __D.aliases.map(norm);
              const label = el => norm([
                el.innerText, el.textContent, el.getAttribute('aria-label'),
                el.getAttribute('title'), el.getAttribute('data-testid')
              ].filter(Boolean).join(' '));
              const visible = el => {
                const r = el.getBoundingClientRect();
                const s = getComputedStyle(el);
                return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
              };
              const matches = el => {
                const value = label(el);
                return visible(el) && aliases.some(a => value === a || value.includes(a));
              };
              const candidates = () => [...document.querySelectorAll(
                'button,[role="menuitem"],[role="option"],[data-testid]'
              )];
              let target = candidates().find(matches);
              if (target) { target.click(); return JSON.stringify({ok:true, direct:true, label:label(target)}); }

              const openers = candidates().filter(visible).filter(el => {
                const value = label(el);
                return value.includes('tool') || value.includes('more') ||
                       value.includes('attach') || value.includes('add photos') ||
                       value === '+' || value.includes('add');
              });
              if (openers.length) {
                openers[0].click();
                await new Promise(r => setTimeout(r, 450));
                target = candidates().find(matches);
                if (target) { target.click(); return JSON.stringify({ok:true, direct:false, label:label(target)}); }
              }
              return JSON.stringify({ok:false});
            })()""",
            {"aliases": list(aliases)},
            timeout=10,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT composer does not currently expose the {mode!r} tool"
            )
        await asyncio.sleep(0.35)

    async def attach_files(self, attachments: list[StoredAttachment]) -> None:
        """Feed local files into ChatGPT's real file input using CDP.

        This makes React own upload progress and message payload construction;
        the bridge never synthesizes a fragile multimodal conversation POST.
        """
        if not attachments:
            return
        paths = [str(item.path.resolve()) for item in attachments]
        names = [item.name for item in attachments]
        for path in paths:
            if not Path(path).is_file():
                raise ParityBrowserError("Staged attachment disappeared before send")

        node_ids = await self._file_input_node_ids()
        if not node_ids:
            await self._open_attachment_picker()
            for _ in range(20):
                node_ids = await self._file_input_node_ids()
                if node_ids:
                    break
                await asyncio.sleep(0.2)
        if not node_ids:
            raise ParityBrowserError("ChatGPT file input was not found")

        response = await self.driver._cdp(
            "DOM.setFileInputFiles",
            {"files": paths, "nodeId": node_ids[-1]},
            timeout=15,
        )
        if response.get("error"):
            raise ParityBrowserError(f"CDP file attachment failed: {response['error']}")

        # Wait until React has consumed the file input / rendered attachment UI.
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const wanted = __D.names;
              const deadline = Date.now() + 30000;
              while (Date.now() < deadline) {
                const body = (document.body && document.body.innerText) || '';
                const inputs = [...document.querySelectorAll('input[type="file"]')];
                const fileNames = inputs.flatMap(i => [...(i.files || [])].map(f => f.name));
                const allVisible = wanted.every(name => body.includes(name) || fileNames.includes(name));
                if (allVisible) return JSON.stringify({ok:true});
                await new Promise(r => setTimeout(r, 250));
              }
              return JSON.stringify({ok:false});
            })()""",
            {"names": names},
            timeout=35,
        )
        if not _json_dict(raw).get("ok"):
            raise ParityBrowserError("Timed out waiting for ChatGPT to accept attachment(s)")

    async def stop_generation(self, conversation_id: str | None = None) -> bool:
        """Stop the active generation through ChatGPT's UI, with API fallback."""
        raw = await self.driver._js_strict(
            """(function () {
              const selectors = [
                '[data-testid="stop-button"]',
                'button[aria-label*="Stop" i]',
                'button[title*="Stop" i]'
              ];
              for (const selector of selectors) {
                const el = document.querySelector(selector);
                if (el) { el.click(); return 'true'; }
              }
              return 'false';
            })()""",
            timeout=5,
        )
        if str(raw).lower() == "true":
            return True
        if not conversation_id:
            conversation_id = getattr(self.driver, "_current_conv_id", None)
        if not conversation_id:
            return False
        token = await self.driver.ensure_token()
        result = await self.driver._js_with_data_strict(
            """(async () => {
              const r = await fetch('/backend-api/stop_conversation', {
                method: 'POST', credentials: 'include',
                headers: {'Content-Type':'application/json', 'Authorization':'Bearer ' + __D.token},
                body: JSON.stringify({conversation_id: __D.conversation_id})
              });
              return JSON.stringify({ok:r.ok, status:r.status, text:(await r.text()).slice(0,300)});
            })()""",
            {"token": token, "conversation_id": conversation_id},
            timeout=15,
        )
        return bool(_json_dict(result).get("ok"))

    async def upload_file_direct(self, attachment: StoredAttachment) -> dict[str, Any]:
        """Upload through ChatGPT's file API using browser auth + Azure SAS.

        Used by voice/data-channel flows where there is no DOM composer file
        input. Ordinary chat attachments should use :meth:`attach_files`.
        """
        token = await self.driver.ensure_token()
        create_raw = await self.driver._js_with_data_strict(
            """(async () => {
              const r = await fetch('/backend-api/files', {
                method:'POST', credentials:'include',
                headers:{'Content-Type':'application/json','Authorization':'Bearer ' + __D.token},
                body:JSON.stringify({
                  file_name:__D.name, file_size:__D.size,
                  use_case:__D.use_case, mime_type:__D.mime_type,
                  supports_direct_azure_multipart:true
                })
              });
              return JSON.stringify({status:r.status, ok:r.ok, data:await r.json()});
            })()""",
            {
                "token": token,
                "name": attachment.name,
                "size": attachment.size,
                "mime_type": attachment.mime_type,
                "use_case": "multimodal"
                if attachment.mime_type.startswith("image/")
                else "my_files",
            },
            timeout=30,
        )
        created = _json_dict(create_raw)
        data = created.get("data") if isinstance(created.get("data"), dict) else {}
        upload_url = data.get("upload_url")
        file_id = data.get("file_id")
        if not created.get("ok") or not isinstance(upload_url, str) or not isinstance(file_id, str):
            raise ParityBrowserError(f"ChatGPT file create failed: {created.get('status')}")

        timeout = aiohttp.ClientTimeout(total=180)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            with attachment.path.open("rb") as handle:
                response = await session.put(
                    upload_url,
                    data=handle,
                    headers={
                        "Content-Type": attachment.mime_type,
                        "x-ms-blob-type": "BlockBlob",
                        "x-ms-version": "2020-04-08",
                        "Origin": "https://chatgpt.com",
                    },
                )
                if response.status >= 400:
                    preview = (await response.text())[:300]
                    raise ParityBrowserError(
                        f"ChatGPT attachment blob upload failed ({response.status}): {preview}"
                    )

        marker_raw = await self.driver._js_with_data_strict(
            """(async () => {
              const r = await fetch('/backend-api/files/' + encodeURIComponent(__D.file_id) + '/uploaded', {
                method:'POST', credentials:'include',
                headers:{'Content-Type':'application/json','Authorization':'Bearer ' + __D.token},
                body:'{}'
              });
              let data = {}; try { data = await r.json(); } catch (_) {}
              return JSON.stringify({ok:r.ok,status:r.status,data});
            })()""",
            {"file_id": file_id, "token": token},
            timeout=30,
        )
        marked = _json_dict(marker_raw)
        if not marked.get("ok"):
            raise ParityBrowserError(f"ChatGPT file uploaded marker failed: {marked.get('status')}")
        return {
            **data,
            **(marked.get("data") if isinstance(marked.get("data"), dict) else {}),
            "file_id": file_id,
            "file_name": attachment.name,
            "file_size": attachment.size,
            "mime_type": attachment.mime_type,
        }

    async def create_voice_session(
        self,
        offer_sdp: str,
        *,
        voice: str = "cove",
        voice_mode: str = "wingman",
        language_code: str = "auto",
    ) -> dict[str, Any]:
        """Proxy the Flutter client's WebRTC offer through the logged-in SPA."""
        if not offer_sdp.strip().startswith("v=0"):
            raise ParityBrowserError("offer_sdp must be WebRTC SDP text")
        token = await self.driver.ensure_token()
        voice = _normalize_voice(voice)
        voice_session_id = str(uuid.uuid4()).upper()
        session = {
            "backend_reasoning_effort": "instant",
            "language_code": language_code or "auto",
            "requested_default_model": "",
            "voice": voice,
            "voice_session_id": voice_session_id,
            "voice_status_request_id": voice_session_id,
            "voice_mode": voice_mode or "wingman",
            "model_slug": "",
            "model_slug_advanced": "",
            "client_tools": [],
            "history_and_training_disabled": False,
            "conversation_mode": {"kind": "primary_assistant"},
            "enable_message_streaming": True,
        }
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const session = {...__D.session};
              session.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
              session.timezone_offset_min = new Date().getTimezoneOffset();
              const form = new FormData();
              form.append('sdp', __D.sdp);
              form.append('session', JSON.stringify(session));
              const r = await fetch('/realtime/wm?dcid=0', {
                method:'POST', credentials:'include',
                headers:{'Authorization':'Bearer ' + __D.token}, body:form
              });
              return JSON.stringify({status:r.status, ok:r.ok, text:await r.text(), ctype:r.headers.get('content-type') || ''});
            })()""",
            {"sdp": offer_sdp, "session": session, "token": token},
            timeout=75,
        )
        result = _json_dict(raw)
        answer = result.get("text")
        if not result.get("ok") or not isinstance(answer, str) or not answer.lstrip().startswith("v=0"):
            raise ParityBrowserError(
                f"ChatGPT realtime voice negotiation failed ({result.get('status')})"
            )
        return {
            "answer_sdp": answer,
            "voice_session_id": voice_session_id,
            "voice": voice,
            "voice_mode": voice_mode or "wingman",
            "content_type": result.get("ctype"),
        }

    async def _file_input_node_ids(self) -> list[int]:
        document = await self.driver._cdp("DOM.getDocument", {"depth": 1, "pierce": True})
        root = document.get("result", {}).get("root", {})
        root_id = root.get("nodeId")
        if not root_id:
            return []
        response = await self.driver._cdp(
            "DOM.querySelectorAll",
            {"nodeId": root_id, "selector": 'input[type="file"]'},
        )
        return [int(item) for item in response.get("result", {}).get("nodeIds", [])]

    async def _open_attachment_picker(self) -> None:
        await self.driver._js_strict(
            """(function () {
              const items = [...document.querySelectorAll('button,[role="button"]')];
              const label = el => ((el.getAttribute('aria-label') || '') + ' ' +
                (el.getAttribute('title') || '') + ' ' + (el.innerText || '')).toLowerCase();
              const el = items.find(x => /attach|add photo|add file|upload/.test(label(x)) || label(x).trim() === '+');
              if (!el) return 'false';
              el.click(); return 'true';
            })()""",
            timeout=5,
        )
        await asyncio.sleep(0.3)


def _safe_filename(value: str) -> str:
    base = Path(value.replace("\\", "/")).name.strip().replace("\x00", "")
    base = re.sub(r"[^\w.()\[\] @+-]", "_", base, flags=re.UNICODE)
    return base[:180] or "attachment"


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


def _normalize_voice(value: str) -> str:
    aliases = {"arbor": "fathom", "sol": "glimmer", "spruce": "orbit"}
    allowed = {
        "breeze",
        "cove",
        "ember",
        "fathom",
        "glimmer",
        "juniper",
        "maple",
        "orbit",
        "vale",
    }
    clean = aliases.get(value.strip().lower(), value.strip().lower())
    return clean if clean in allowed else "cove"
