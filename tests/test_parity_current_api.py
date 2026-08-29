from contextlib import asynccontextmanager
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest

from sloppa.parity_current_api import CurrentParityAPIServer


@asynccontextmanager
async def _guard():
    yield


def _guard_factory():
    return _guard()


def _timeout(_body, _mode):
    return 120.0


@pytest.mark.asyncio
async def test_rich_send_navigates_before_model_and_composer_controls():
    order: list[str] = []
    server = object.__new__(CurrentParityAPIServer)
    server._config = SimpleNamespace(
        chatgpt=SimpleNamespace(default_model="auto"),
    )
    server._last_project_id = None
    server._mutation_guard = _guard_factory
    server._send_timeout = _timeout

    driver = MagicMock()
    driver.navigate_new_chat = AsyncMock(
        side_effect=lambda gizmo_id=None: order.append("navigate")
    )
    driver.select_model = AsyncMock(
        side_effect=lambda slug: order.append("model") or True
    )
    server._driver = driver

    browser = MagicMock()
    browser.select_tool = AsyncMock(side_effect=lambda mode: order.append("tool"))
    browser.select_plugin = AsyncMock(side_effect=lambda name: order.append("plugin"))
    browser.attach_files = AsyncMock(
        side_effect=lambda attachments: order.append("attachments")
    )
    browser.set_temporary_chat = AsyncMock()
    server._parity_browser = browser

    reasoning = MagicMock()
    reasoning.set_level = AsyncMock(
        side_effect=lambda level: order.append("reasoning")
    )
    server._reasoning = reasoning

    library = MagicMock()
    library.attach_items = AsyncMock(
        side_effect=lambda names: order.append("library")
    )
    server._library = library

    expected = object()

    async def full_response(model, prompt, timeout, *, mode):
        del model, prompt, timeout, mode
        order.append("send")
        return expected

    server._full_rich_response = full_response

    result = await server._execute_rich_send(
        MagicMock(),
        {
            "model": "gpt-5.6",
            "reasoning_level": "high",
            "mode": "search",
            "plugin": "Example App",
            "library_files": ["brief.pdf"],
            "stream": False,
        },
        "hello",
        [],
    )

    assert result is expected
    assert order == [
        "navigate",
        "model",
        "reasoning",
        "tool",
        "plugin",
        "library",
        "attachments",
        "send",
    ]


@pytest.mark.asyncio
async def test_rich_send_rejects_temporary_on_existing_conversation():
    server = object.__new__(CurrentParityAPIServer)
    server._config = SimpleNamespace(
        chatgpt=SimpleNamespace(default_model="auto"),
    )
    server._send_timeout = _timeout

    response = await server._execute_rich_send(
        MagicMock(),
        {
            "conversation_id": "conv-1",
            "temporary": True,
            "stream": False,
        },
        "hello",
        [],
    )

    assert response.status == 400
