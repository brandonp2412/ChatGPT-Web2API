import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from aiohttp.test_utils import make_mocked_request

from sloppa.parity_api import ParityAPIServer


@pytest.mark.asyncio
async def test_conversation_list_rejects_non_numeric_pagination():
    server = object.__new__(ParityAPIServer)
    server._config = SimpleNamespace(server=SimpleNamespace(api_keys=[]))
    server._driver = SimpleNamespace(get_conversations=AsyncMock())
    server._check_auth = lambda request: None

    response = await server._handle_conversations(
        make_mocked_request("GET", "/v1/conversations?offset=oops&limit=10")
    )

    assert response.status == 400
    server._driver.get_conversations.assert_not_awaited()


@pytest.mark.asyncio
async def test_conversation_list_rejects_negative_pagination():
    server = object.__new__(ParityAPIServer)
    server._config = SimpleNamespace(server=SimpleNamespace(api_keys=[]))
    server._driver = SimpleNamespace(get_conversations=AsyncMock())
    server._check_auth = lambda request: None

    response = await server._handle_conversations(
        make_mocked_request("GET", "/v1/conversations?offset=-1&limit=10")
    )

    assert response.status == 400
    server._driver.get_conversations.assert_not_awaited()


@pytest.mark.asyncio
async def test_conversation_search_rejects_unbounded_query():
    server = object.__new__(ParityAPIServer)
    server._config = SimpleNamespace(server=SimpleNamespace(api_keys=[]))
    server._parity_actions = SimpleNamespace(search_conversations=AsyncMock())
    server._check_auth = lambda request: None

    response = await server._handle_conversation_search(
        make_mocked_request("GET", "/v1/conversations/search?query=" + "x" * 501)
    )

    assert response.status == 400
    server._parity_actions.search_conversations.assert_not_awaited()


@pytest.mark.asyncio
async def test_conversation_list_tolerates_non_list_driver_result():
    server = object.__new__(ParityAPIServer)
    server._config = SimpleNamespace(server=SimpleNamespace(api_keys=[]))
    server._driver = SimpleNamespace(get_conversations=AsyncMock(return_value=None))
    server._check_auth = lambda request: None

    response = await server._handle_conversations(
        make_mocked_request("GET", "/v1/conversations?limit=10")
    )

    assert response.status == 200
    assert json.loads(response.text)["data"] == []


@pytest.mark.asyncio
async def test_conversation_list_rejects_unknown_order():
    server = object.__new__(ParityAPIServer)
    server._config = SimpleNamespace(server=SimpleNamespace(api_keys=[]))
    server._driver = SimpleNamespace(get_conversations=AsyncMock())
    server._check_auth = lambda request: None

    response = await server._handle_conversations(
        make_mocked_request("GET", "/v1/conversations?order=unsupported")
    )

    assert response.status == 400
    server._driver.get_conversations.assert_not_awaited()
