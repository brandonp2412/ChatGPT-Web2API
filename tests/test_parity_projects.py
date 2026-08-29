from unittest.mock import AsyncMock, MagicMock

import pytest

from sloppa.parity_projects import ProjectController


@pytest.mark.asyncio
async def test_project_conversations_use_cursor_endpoint():
    driver = MagicMock()
    driver.ensure_token = AsyncMock(return_value="token")
    driver._js_with_data_strict = AsyncMock(
        return_value='{"ok":true,"status":200,"data":{"items":[],"cursor":null}}'
    )
    controller = ProjectController(driver)

    data = await controller.list_conversations("g-p-abc", cursor="next cursor")

    assert data == {"items": [], "cursor": None}
    payload = driver._js_with_data_strict.await_args.args[1]
    assert payload["path"] == (
        "/backend-api/gizmos/g-p-abc/conversations?cursor=next%20cursor"
    )


@pytest.mark.asyncio
async def test_project_file_resolution_includes_gizmo_id():
    driver = MagicMock()
    driver.ensure_token = AsyncMock(return_value="token")
    driver._js_with_data_strict = AsyncMock(
        return_value=(
            '{"ok":true,"status":200,"data":'
            '{"download_url":"https://files.oaiusercontent.com/x"}}'
        )
    )
    controller = ProjectController(driver)

    data = await controller.project_file_download_url(
        "g-p-project",
        "file-123",
        inline=True,
    )

    assert data["download_url"].startswith("https://")
    payload = driver._js_with_data_strict.await_args.args[1]
    assert payload["path"] == (
        "/backend-api/files/download/file-123"
        "?gizmo_id=g-p-project&inline=true"
    )
