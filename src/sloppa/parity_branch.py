"""Conversation-branch selection through ChatGPT's own response pager."""

from __future__ import annotations

import asyncio
import json
from typing import Any

from .parity_browser import ParityBrowserError
from .parity_models import normalize_message


class BranchController:
    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def select_node(
        self,
        conversation_id: str,
        target_node_id: str,
    ) -> dict[str, Any]:
        raw = await self.driver.get_conversation(conversation_id)
        mapping = raw.get("mapping") if isinstance(raw, dict) else None
        if not isinstance(mapping, dict) or target_node_id not in mapping:
            raise ParityBrowserError("Target branch node does not exist")

        plan = branch_switch_plan(
            mapping,
            str(raw.get("current_node") or ""),
            target_node_id,
        )
        await self.driver.navigate_conversation(conversation_id)
        if plan["steps"] == 0:
            return {**plan, "verified": True}

        siblings = plan["siblings"]
        current_index = plan["current_index"]
        target_index = plan["target_index"]
        direction = 1 if target_index > current_index else -1
        index = current_index

        while index != target_index:
            current_node_id = siblings[index]
            node = mapping.get(current_node_id)
            message = node.get("message") if isinstance(node, dict) else None
            normalized = (
                normalize_message(message, node_id=current_node_id, node=node)
                if isinstance(message, dict) and isinstance(node, dict)
                else None
            )
            message_id = str(message.get("id") or "") if isinstance(message, dict) else ""
            message_text = str(normalized.get("text") or "") if normalized else ""
            await self._click_step(
                direction,
                message_id=message_id,
                message_text=message_text,
            )
            index += direction
            await asyncio.sleep(0.25)

        target_child = siblings[target_index]
        target_node = mapping.get(target_child)
        target_message = (
            target_node.get("message") if isinstance(target_node, dict) else None
        )
        normalized_target = (
            normalize_message(
                target_message,
                node_id=target_child,
                node=target_node,
            )
            if isinstance(target_message, dict) and isinstance(target_node, dict)
            else None
        )
        target_text = str(normalized_target.get("text") or "") if normalized_target else ""
        verified = await self._verify_visible(target_text)
        return {**plan, "verified": verified}

    async def _click_step(
        self,
        direction: int,
        *,
        message_id: str,
        message_text: str,
    ) -> None:
        raw = await self.driver._js_with_data_strict(
            """(() => {
              const norm=s=>(s||'').toLowerCase().replace(/\\s+/g,' ').trim();
              const visible=el=>{const r=el.getBoundingClientRect(),s=getComputedStyle(el);
                return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
              const label=el=>norm([el.innerText,el.textContent,el.getAttribute('aria-label'),
                el.getAttribute('title'),el.getAttribute('data-testid')].filter(Boolean).join(' '));
              let message=null;
              if(__D.message_id){
                message=document.querySelector('[data-message-id="'+CSS.escape(__D.message_id)+'"]');
              }
              if(!message&&__D.message_text){
                const needle=norm(__D.message_text).slice(0,120);
                message=[...document.querySelectorAll('[data-message-author-role]')]
                  .find(el=>norm(el.innerText).includes(needle))||null;
              }
              const aliases=__D.direction>0
                ? ['next response','next answer','next']
                : ['previous response','previous answer','previous'];
              const matches=el=>visible(el)&&aliases.some(a=>label(el)===a||label(el).includes(a));
              let button=null;
              if(message){
                let root=message.closest('article,[data-testid^="conversation-turn"]')||message.parentElement;
                for(let depth=0;root&&depth<4&&!button;depth++,root=root.parentElement){
                  button=[...root.querySelectorAll('button,[role="button"]')].find(matches)||null;
                }
              }
              if(!button){
                const all=[...document.querySelectorAll('button,[role="button"]')].filter(matches);
                if(all.length===1)button=all[0];
              }
              if(!button)return JSON.stringify({ok:false});
              button.click();return JSON.stringify({ok:true,label:label(button)});
            })()""",
            {
                "direction": direction,
                "message_id": message_id,
                "message_text": message_text,
            },
            timeout=8,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            name = "next" if direction > 0 else "previous"
            raise ParityBrowserError(f"ChatGPT {name} response control was not found")

    async def _verify_visible(self, text: str) -> bool:
        if not text:
            return True
        raw = await self.driver._js_with_data_strict(
            """(() => {
              const norm=s=>(s||'').replace(/\\s+/g,' ').trim();
              const needle=norm(__D.text).slice(0,160);
              return JSON.stringify({
                ok:[...document.querySelectorAll('[data-message-author-role]')]
                  .some(el=>norm(el.innerText).includes(needle))
              });
            })()""",
            {"text": text},
            timeout=5,
        )
        return bool(_json_dict(raw).get("ok"))


def branch_switch_plan(
    mapping: dict[str, Any],
    current_node_id: str,
    target_node_id: str,
) -> dict[str, Any]:
    """Plan the first branch divergence needed to make target's branch active."""
    current = _path(mapping, current_node_id)
    target = _path(mapping, target_node_id)
    if not target:
        raise ParityBrowserError("Target branch has no valid path")
    if not current:
        raise ParityBrowserError("Current conversation branch has no valid path")

    common = 0
    while common < min(len(current), len(target)) and current[common] == target[common]:
        common += 1

    if common == len(target):
        return {
            "target_node_id": target_node_id,
            "divergence_parent": target[-1],
            "siblings": [target[-1]],
            "current_index": 0,
            "target_index": 0,
            "steps": 0,
        }
    if common == len(current):
        # The target is a descendant of the already-active branch. No sibling
        # pager operation is necessary to make that branch active.
        return {
            "target_node_id": target_node_id,
            "divergence_parent": current[-1],
            "siblings": [target[common]],
            "current_index": 0,
            "target_index": 0,
            "steps": 0,
        }
    if common == 0:
        raise ParityBrowserError("Conversation branches do not share a root")

    parent_id = current[common - 1]
    parent = mapping.get(parent_id)
    siblings = parent.get("children") if isinstance(parent, dict) else None
    if not isinstance(siblings, list):
        raise ParityBrowserError("Branch parent has no sibling list")
    siblings = [str(item) for item in siblings]
    current_child = current[common]
    target_child = target[common]
    try:
        current_index = siblings.index(current_child)
        target_index = siblings.index(target_child)
    except ValueError as exc:
        raise ParityBrowserError("Branch sibling topology is inconsistent") from exc

    return {
        "target_node_id": target_node_id,
        "divergence_parent": parent_id,
        "siblings": siblings,
        "current_index": current_index,
        "target_index": target_index,
        "steps": abs(target_index - current_index),
    }


def _path(mapping: dict[str, Any], node_id: str) -> list[str]:
    if not node_id:
        return []
    result: list[str] = []
    seen: set[str] = set()
    current: str | None = node_id
    while current and current not in seen:
        seen.add(current)
        node = mapping.get(current)
        if not isinstance(node, dict):
            return []
        result.append(current)
        parent = node.get("parent")
        current = str(parent) if parent else None
    result.reverse()
    return result


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
