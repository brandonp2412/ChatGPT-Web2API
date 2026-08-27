from unittest.mock import AsyncMock, MagicMock

import pytest

from chatgpt_web2api.parity_research import (
    RichConversationController,
    extract_research_reports,
)


def test_research_report_extracts_visible_text_citations_and_assets():
    raw = {
        "mapping": {},
        "connector_state": {
            "widget_state": {
                "report_message": {
                    "id": "report-1",
                    "content": {
                        "parts": ["Research result"],
                    },
                    "citations": [
                        {
                            "url": "https://example.com/source",
                            "title": "Source",
                            "text": "Evidence",
                        }
                    ],
                    "attachment": {
                        "asset_pointer": "sediment://file-1",
                        "mime_type": "application/pdf",
                        "file_name": "report.pdf",
                    },
                    "status": "complete",
                }
            }
        },
    }

    reports = extract_research_reports(raw)

    assert len(reports) == 1
    report = reports[0]
    assert report["id"] == "report-1"
    assert report["text"] == "Research result"
    assert report["citations"][0]["url"] == "https://example.com/source"
    assert report["assets"][0]["asset_pointer"] == "sediment://file-1"
    assert "widget_state" not in str(report)


def test_research_report_ignores_empty_widget_payloads():
    raw = {"widget_state": {"report_message": {"status": "pending"}}}

    assert extract_research_reports(raw) == []


@pytest.mark.asyncio
async def test_rich_conversation_uses_widget_state_query_when_available():
    driver = MagicMock()
    driver.ensure_token = AsyncMock(return_value="token")
    driver._js_with_data_strict = AsyncMock(
        return_value=(
            '{"ok":true,"status":200,"data":'
            '{"id":"conv-1","mapping":{},"widget_state":{}}}'
        )
    )
    controller = RichConversationController(driver)

    result = await controller.fetch("conv-1")

    assert result["id"] == "conv-1"
    payload = driver._js_with_data_strict.await_args.args[1]
    assert payload["path"] == (
        "/backend-api/conversation/conv-1?include_widget_state=true"
    )


@pytest.mark.asyncio
async def test_rich_conversation_falls_back_when_widget_query_is_unsupported():
    driver = MagicMock()
    driver.ensure_token = AsyncMock(return_value="token")
    driver._js_with_data_strict = AsyncMock(
        return_value='{"ok":false,"status":400,"data":null}'
    )
    driver.get_conversation = AsyncMock(
        return_value={"id": "conv-1", "mapping": {}}
    )
    controller = RichConversationController(driver)

    result = await controller.fetch("conv-1")

    assert result["id"] == "conv-1"
    driver.get_conversation.assert_awaited_once_with("conv-1")
