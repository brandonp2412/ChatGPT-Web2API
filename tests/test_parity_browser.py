from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest

from sloppa.parity_browser import (
    AttachmentStore,
    AttachmentTooLargeError,
    ParityBrowser,
)


class FakeField:
    def __init__(self, chunks, *, filename="../../unsafe name.png", content_type="image/png"):
        self.filename = filename
        self.headers = {"Content-Type": content_type}
        self._chunks = list(chunks)

    async def read_chunk(self, size=0):
        del size
        return self._chunks.pop(0) if self._chunks else b""


@pytest.mark.asyncio
async def test_attachment_store_sanitizes_and_deletes_one_shot_file():
    store = AttachmentStore(max_bytes=1024)
    try:
        item = await store.put_multipart_field(FakeField([b"abc", b"def"]))
        assert item.name == "unsafe name.png"
        assert item.size == 6
        assert item.path.parent == store.root
        assert item.path.read_bytes() == b"abcdef"

        resolved = await store.get_many([item.id])
        assert resolved == [item]
        assert await store.delete(item.id) is True
        assert not item.path.exists()
        assert await store.delete(item.id) is False
    finally:
        root = store.root
        await store.close()
        assert not Path(root).exists()


@pytest.mark.asyncio
async def test_attachment_store_rejects_oversized_upload_without_leaving_file():
    store = AttachmentStore(max_bytes=3)
    try:
        with pytest.raises(AttachmentTooLargeError):
            await store.put_multipart_field(FakeField([b"abcd"]))
        assert list(store.root.iterdir()) == []
    finally:
        await store.close()


@pytest.mark.asyncio
async def test_select_tool_delegates_choice_to_logged_in_spa():
    driver = MagicMock()
    driver._js_with_data_strict = AsyncMock(
        return_value='{"ok":true,"direct":false,"label":"deep research"}'
    )
    browser = ParityBrowser(driver)

    await browser.select_tool("deep-research")

    payload = driver._js_with_data_strict.await_args.args[1]
    assert "deep research" in payload["aliases"]


@pytest.mark.asyncio
async def test_voice_session_returns_answer_sdp_without_exposing_access_token():
    driver = MagicMock()
    driver.ensure_token = AsyncMock(return_value="secret-token")
    driver._js_with_data_strict = AsyncMock(
        return_value='{"status":200,"ok":true,"text":"v=0\\r\\na=answer","ctype":"application/sdp"}'
    )
    browser = ParityBrowser(driver)

    result = await browser.create_voice_session("v=0\r\na=offer", voice="sol")

    assert result["answer_sdp"].startswith("v=0")
    assert result["voice"] == "glimmer"
    assert "secret-token" not in str(result)
