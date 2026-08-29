"""Current ChatGPT web controls that are intentionally discovered at runtime.

These controls cover product surfaces whose DOM/options vary by plan and rollout:
GPT-5.6 reasoning levels, saved-file Library selection, and intermediate actions
such as Deep Research plan approval. No ChatGPT credentials leave the browser.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

from .parity_browser import ParityBrowserError

_REASONING_ALIASES: dict[str, tuple[str, ...]] = {
    "instant": ("instant",),
    "medium": ("medium", "standard"),
    "high": ("high", "extended"),
    "extra_high": ("extra high", "extra-high", "very high"),
    "pro": ("pro",),
    "think": ("think",),
}

_ACTION_HINTS = (
    "start research",
    "begin research",
    "edit plan",
    "modify plan",
    "continue",
    "confirm",
    "allow",
    "approve",
    "cancel",
    "stop",
    "retry",
    "use source",
    "add source",
)


class ReasoningController:
    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def available_levels(self) -> list[str]:
        """Discover reasoning levels currently exposed by the model picker."""
        raw = await self.driver._js_strict(
            """(async () => {
              const norm=s=>(s||'').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible=el=>{const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
              const label=el=>norm([el.innerText,el.textContent,el.getAttribute('aria-label'),
                el.getAttribute('title')].filter(Boolean).join(' '));
              const controls=()=>[...document.querySelectorAll(
                'button,[role="menuitem"],[role="option"],[role="radio"],[role="slider"],[data-testid]'
              )].filter(visible);
              const picker=controls().find(el=>{
                const v=label(el); return v.includes('model')||v.includes('gpt-5.6')||v.includes('reasoning');
              });
              if(picker){picker.click();await new Promise(r=>setTimeout(r,350));}
              const wanted=['instant','medium','high','extra high','pro','think'];
              const found=[];
              for(const el of controls()){
                const v=label(el);
                for(const level of wanted){
                  if((v===level||v.includes(level))&&!found.includes(level))found.push(level);
                }
              }
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
              return JSON.stringify(found);
            })()""",
            timeout=10,
        )
        data = _json_list(raw)
        return [str(item) for item in data if isinstance(item, str)]

    async def set_level(self, level: str | None) -> None:
        clean = (level or "").strip().lower().replace("-", "_").replace(" ", "_")
        if not clean or clean == "auto":
            return
        aliases = _REASONING_ALIASES.get(clean)
        if not aliases:
            raise ParityBrowserError(
                "reasoning_level must be instant, medium, high, extra_high, pro, or think"
            )
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const norm=s=>(s||'').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible=el=>{const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
              const label=el=>norm([el.innerText,el.textContent,el.getAttribute('aria-label'),
                el.getAttribute('title'),el.getAttribute('data-testid')].filter(Boolean).join(' '));
              const controls=()=>[...document.querySelectorAll(
                'button,[role="menuitem"],[role="option"],[role="radio"],[data-testid]'
              )].filter(visible);
              const matches=el=>__D.aliases.some(a=>label(el)===a||label(el).includes(a));
              let target=controls().find(matches);
              if(!target){
                const picker=controls().find(el=>{
                  const v=label(el); return v.includes('model')||v.includes('gpt-5.6')||v.includes('reasoning');
                });
                if(picker){picker.click();await new Promise(r=>setTimeout(r,400));target=controls().find(matches);}
              }
              if(!target)return JSON.stringify({ok:false});
              target.click(); return JSON.stringify({ok:true,label:label(target)});
            })()""",
            {"aliases": list(aliases)},
            timeout=12,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT does not expose reasoning level {level!r} for the active account/model"
            )
        await asyncio.sleep(0.35)


class LibraryController:
    """Drive the ChatGPT saved-file Library picker without private file APIs."""

    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def list_items(self) -> list[dict[str, str]]:
        raw = await self.driver._js_strict(self._library_script(select=False), timeout=15)
        data = _json_list(raw)
        return [
            {"name": str(item.get("name", "")), "detail": str(item.get("detail", ""))}
            for item in data
            if isinstance(item, dict) and item.get("name")
        ]

    async def attach_items(self, names: list[str]) -> None:
        clean = [name.strip() for name in names if isinstance(name, str) and name.strip()]
        if not clean:
            return
        raw = await self.driver._js_with_data_strict(
            self._library_script(select=True),
            {"names": clean},
            timeout=20,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            missing = result.get("missing") or clean
            raise ParityBrowserError(f"ChatGPT Library file(s) not found: {missing}")
        await asyncio.sleep(0.4)

    @staticmethod
    def _library_script(*, select: bool) -> str:
        select_block = """
              const missing=[];
              for(const wanted of __D.names){
                const needle=norm(wanted);
                const item=rows().find(el=>label(el).includes(needle));
                if(!item){missing.push(wanted);continue;}
                const clickable=item.closest('button,[role="option"],[role="checkbox"],[role="row"]')||item;
                clickable.click(); await new Promise(r=>setTimeout(r,100));
              }
              if(missing.length)return JSON.stringify({ok:false,missing});
              const confirm=controls().find(el=>/add|attach|done|select/.test(label(el)));
              if(confirm)confirm.click();
              return JSON.stringify({ok:true});
        """ if select else """
              const out=[]; const seen=new Set();
              for(const el of rows()){
                const v=(el.innerText||el.textContent||'').replace(/\\s+/g,' ').trim();
                if(!v||v.length>240||seen.has(v))continue;
                seen.add(v); out.push({name:v.split('\\n')[0].trim(),detail:v});
              }
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
              return JSON.stringify(out.slice(0,200));
        """
        return """(async () => {
              const norm=s=>(s||'').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible=el=>{const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
              const label=el=>norm([el.innerText,el.textContent,el.getAttribute('aria-label'),
                el.getAttribute('title')].filter(Boolean).join(' '));
              const controls=()=>[...document.querySelectorAll(
                'button,[role="button"],[role="menuitem"],[role="option"],[data-testid]'
              )].filter(visible);
              const library=()=>controls().find(el=>label(el).includes('add from library')||label(el)==='library');
              let lib=library();
              if(!lib){
                const opener=controls().find(el=>{
                  const v=label(el); return v==='+'||v.includes('attach')||v.includes('add photos')||v.includes('more');
                });
                if(opener){opener.click();await new Promise(r=>setTimeout(r,350));lib=library();}
              }
              if(!lib)return JSON.stringify({ok:false,stage:'library_menu'});
              lib.click(); await new Promise(r=>setTimeout(r,500));
              const rows=()=>[...document.querySelectorAll(
                '[role="dialog"] [role="option"],[role="dialog"] [role="row"],'+
                '[role="dialog"] [role="checkbox"],[role="dialog"] button,[role="dialog"] [data-testid]'
              )].filter(visible);
        """ + select_block + "\n            })()"


class UIActionController:
    """Expose intermediate in-chat actions, notably Deep Research plan controls."""

    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def list_actions(self) -> list[dict[str, str]]:
        raw = await self.driver._js_with_data_strict(
            """(() => {
              const norm=s=>(s||'').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible=el=>{const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
              const label=el=>(el.innerText||el.textContent||el.getAttribute('aria-label')||el.getAttribute('title')||'').replace(/\\s+/g,' ').trim();
              const hints=__D.hints; const out=[]; const seen=new Set();
              for(const el of document.querySelectorAll('button,[role="button"],[role="menuitem"]')){
                if(!visible(el))continue; const text=label(el); const n=norm(text);
                if(!text||seen.has(text)||!hints.some(h=>n.includes(h)))continue;
                seen.add(text); out.push({label:text,testid:el.getAttribute('data-testid')||''});
              }
              return JSON.stringify(out.slice(0,50));
            })()""",
            {"hints": list(_ACTION_HINTS)},
            timeout=8,
        )
        data = _json_list(raw)
        return [
            {"label": str(item.get("label", "")), "testid": str(item.get("testid", ""))}
            for item in data
            if isinstance(item, dict) and item.get("label")
        ]

    async def trigger(self, label: str) -> None:
        wanted = label.strip()
        if not wanted:
            raise ParityBrowserError("action label is required")
        normalized = wanted.lower()
        if not any(hint in normalized or normalized in hint for hint in _ACTION_HINTS):
            raise ParityBrowserError("Refusing non-chat intermediate UI action")
        raw = await self.driver._js_with_data_strict(
            """(() => {
              const norm=s=>(s||'').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible=el=>{const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
              const label=el=>norm(el.innerText||el.textContent||el.getAttribute('aria-label')||el.getAttribute('title')||'');
              const wanted=norm(__D.label);
              const target=[...document.querySelectorAll('button,[role="button"],[role="menuitem"]')]
                .find(el=>visible(el)&&(label(el)===wanted||label(el).includes(wanted)));
              if(!target)return JSON.stringify({ok:false});
              target.click(); return JSON.stringify({ok:true,label:label(target)});
            })()""",
            {"label": wanted},
            timeout=8,
        )
        if not _json_dict(raw).get("ok"):
            raise ParityBrowserError(f"ChatGPT intermediate action is no longer visible: {wanted}")
        await asyncio.sleep(0.25)


def _json_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            data = json.loads(value)
        except json.JSONDecodeError:
            return {}
        return data if isinstance(data, dict) else {}
    return {}


def _json_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        try:
            data = json.loads(value)
        except json.JSONDecodeError:
            return []
        return data if isinstance(data, list) else []
    return []
