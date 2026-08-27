"""Read-only live canaries for current ChatGPT chat-window parity.

Run with:
    W2A_E2E_RUN=1 pytest tests/test_e2e_parity_current.py -m e2e -v

These tests only open/dismiss existing ChatGPT controls. They do not create,
rename, archive, share, upload, send, or delete account data.
"""

import pytest

from chatgpt_web2api.cdp_driver import CDPDriver
from chatgpt_web2api.parity_browser import ParityBrowser
from chatgpt_web2api.parity_current_controls import (
    LibraryController,
    ReasoningController,
    UIActionController,
)

pytestmark = pytest.mark.e2e


async def test_current_model_picker_reasoning_surface_is_parseable(
    e2e_driver: CDPDriver,
):
    levels = await ReasoningController(e2e_driver).available_levels()
    allowed = {"instant", "medium", "high", "extra high", "pro", "think"}
    assert set(levels) <= allowed


async def test_current_composer_tool_menu_is_parseable(e2e_driver: CDPDriver):
    tools = await ParityBrowser(e2e_driver).discover_composer_tools()
    assert isinstance(tools, list)
    for item in tools:
        assert item["label"].strip()


async def test_current_library_picker_is_parseable(e2e_driver: CDPDriver):
    items = await LibraryController(e2e_driver).list_items()
    assert isinstance(items, list)
    for item in items:
        assert item["name"].strip()


async def test_current_intermediate_actions_are_allowlisted(e2e_driver: CDPDriver):
    actions = await UIActionController(e2e_driver).list_actions()
    assert isinstance(actions, list)
    for action in actions:
        assert action["label"].strip()
