"""ChatGPT Project reads not covered by the original bridge helpers."""

from __future__ import annotations

import json
import urllib.parse
from typing import Any

from .parity_browser import ParityBrowserError


class ProjectController:
    def __init__(self, driver: Any) -> None:
        self.driver = driver

    async def list_conversations(
        self,
        project_id: str,
        *,
        cursor: str = "0",
    ) -> dict[str, Any]:
        project = urllib.parse.quote(project_id, safe="")
        encoded_cursor = urllib.parse.quote(cursor or "0", safe="")
        path = f"/backend-api/gizmos/{project}/conversations?cursor={encoded_cursor}"
        data = await self._backend_json(path)
        if not isinstance(data, dict):
            raise ParityBrowserError("ChatGPT project conversation list was malformed")
        return data

    async def project_file_download_url(
        self,
        project_id: str,
        file_id: str,
        *,
        inline: bool = False,
    ) -> dict[str, Any]:
        file_part = urllib.parse.quote(file_id, safe="")
        project_part = urllib.parse.quote(project_id, safe="")
        path = (
            f"/backend-api/files/download/{file_part}"
            f"?gizmo_id={project_part}&inline={'true' if inline else 'false'}"
        )
        data = await self._backend_json(path)
        if not isinstance(data, dict) or not data.get("download_url"):
            raise ParityBrowserError("ChatGPT project file resolution returned no URL")
        return data

    async def _backend_json(self, path: str) -> Any:
        token = await self.driver.ensure_token()
        raw = await self.driver._js_with_data_strict(
            """(async () => {
              const r=await fetch(__D.path,{
                credentials:'include',headers:{'Authorization':'Bearer '+__D.token}
              });
              const text=await r.text();let data=null;
              if(text){try{data=JSON.parse(text);}catch(_){data={detail:text.slice(0,1000)};}}
              return JSON.stringify({ok:r.ok,status:r.status,data});
            })()""",
            {"path": path, "token": token},
            timeout=30,
        )
        result = _json_dict(raw)
        if not result.get("ok"):
            raise ParityBrowserError(
                f"ChatGPT project request failed ({result.get('status')}): "
                f"{result.get('data')}"
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
