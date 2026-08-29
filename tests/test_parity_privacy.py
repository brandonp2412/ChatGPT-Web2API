from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest
from aiohttp.test_utils import make_mocked_request

from sloppa.parity_privacy_api import PrivacyParityAPIServer
from sloppa.parity_secure_api import _client_view


def test_client_view_does_not_surface_hidden_raw_context():
    raw = {
        "id": "conv-1",
        "current_node": "hidden",
        "mapping": {
            "root": {"parent": None, "children": ["hidden"], "message": None},
            "hidden": {
                "parent": "root",
                "children": [],
                "message": {
                    "id": "secret",
                    "author": {"role": "system"},
                    "content": {
                        "content_type": "model_editable_context",
                        "parts": ["private internal material"],
                    },
                    "metadata": {"is_visually_hidden_from_conversation": True},
                },
            },
        },
    }

    view = _client_view(raw)

    assert "private internal material" not in str(view)
    assert view["nodes"]["hidden"]["message"] is None


@pytest.mark.asyncio
async def test_raw_query_is_rejected_before_fetching_conversation():
    server = object.__new__(PrivacyParityAPIServer)
    server._config = SimpleNamespace(server=SimpleNamespace(api_keys=[]))
    server._rich_conversation = MagicMock()
    server._rich_conversation.fetch = AsyncMock()
    server._check_auth = lambda request: None

    request = make_mocked_request("GET", "/v1/conversations/c1?raw=1")
    response = await server._handle_conversation(request)

    assert response.status == 400
    server._rich_conversation.fetch.assert_not_awaited()


@pytest.mark.asyncio
async def test_canvas_mode_is_rejected_without_touching_browser():
    server = object.__new__(PrivacyParityAPIServer)

    response = await server._execute_rich_send(
        MagicMock(),
        {"mode": "canvas"},
        "hello",
        [],
    )

    assert response.status == 400
