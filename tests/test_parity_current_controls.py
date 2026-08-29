from unittest.mock import AsyncMock, MagicMock

import pytest

from sloppa.parity_browser import ParityBrowserError
from sloppa.parity_current_controls import (
    LibraryController,
    ReasoningController,
    UIActionController,
)


@pytest.mark.asyncio
async def test_reasoning_controller_discovers_current_picker_levels():
    driver = MagicMock()
    driver._js_strict = AsyncMock(
        return_value='["instant","medium","high","extra high","pro"]'
    )
    controller = ReasoningController(driver)

    levels = await controller.available_levels()

    assert levels == ["instant", "medium", "high", "extra high", "pro"]


@pytest.mark.asyncio
async def test_reasoning_controller_maps_extra_high_to_visible_picker_label(monkeypatch):
    driver = MagicMock()
    driver._js_with_data_strict = AsyncMock(
        return_value='{"ok":true,"label":"extra high"}'
    )
    monkeypatch.setattr(
        "sloppa.parity_current_controls.asyncio.sleep", AsyncMock()
    )
    controller = ReasoningController(driver)

    await controller.set_level("extra-high")

    payload = driver._js_with_data_strict.await_args.args[1]
    assert "extra high" in payload["aliases"]


@pytest.mark.asyncio
async def test_reasoning_controller_rejects_unknown_level():
    controller = ReasoningController(MagicMock())

    with pytest.raises(ParityBrowserError, match="reasoning_level"):
        await controller.set_level("maximum-plus")


@pytest.mark.asyncio
async def test_library_controller_lists_visible_saved_files():
    driver = MagicMock()
    driver._js_strict = AsyncMock(
        return_value='[{"name":"brief.pdf","detail":"brief.pdf 2 MB"}]'
    )
    controller = LibraryController(driver)

    items = await controller.list_items()

    assert items == [{"name": "brief.pdf", "detail": "brief.pdf 2 MB"}]


@pytest.mark.asyncio
async def test_library_controller_selects_requested_files(monkeypatch):
    driver = MagicMock()
    driver._js_with_data_strict = AsyncMock(return_value='{"ok":true}')
    monkeypatch.setattr(
        "sloppa.parity_current_controls.asyncio.sleep", AsyncMock()
    )
    controller = LibraryController(driver)

    await controller.attach_items(["brief.pdf", "image.png"])

    payload = driver._js_with_data_strict.await_args.args[1]
    assert payload["names"] == ["brief.pdf", "image.png"]


@pytest.mark.asyncio
async def test_library_controller_fails_closed_when_file_is_missing():
    driver = MagicMock()
    driver._js_with_data_strict = AsyncMock(
        return_value='{"ok":false,"missing":["missing.pdf"]}'
    )
    controller = LibraryController(driver)

    with pytest.raises(ParityBrowserError, match="missing.pdf"):
        await controller.attach_items(["missing.pdf"])


@pytest.mark.asyncio
async def test_ui_actions_only_exposes_relevant_chat_controls():
    driver = MagicMock()
    driver._js_with_data_strict = AsyncMock(
        return_value='[{"label":"Start research","testid":"start-research"}]'
    )
    controller = UIActionController(driver)

    actions = await controller.list_actions()

    assert actions == [
        {"label": "Start research", "testid": "start-research"}
    ]


@pytest.mark.asyncio
async def test_ui_action_rejects_arbitrary_page_click():
    controller = UIActionController(MagicMock())

    with pytest.raises(ParityBrowserError, match="non-chat"):
        await controller.trigger("Delete account")
