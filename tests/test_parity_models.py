from sloppa.parity_models import (
    current_branch_ids,
    normalize_conversation,
)


def _conversation():
    return {
        "id": "conv-1",
        "title": "Parity",
        "current_node": "a2",
        "mapping": {
            "root": {"id": "root", "parent": None, "children": ["u1"], "message": None},
            "u1": {
                "id": "u1",
                "parent": "root",
                "children": ["a1", "a2"],
                "message": {
                    "id": "m-u1",
                    "author": {"role": "user"},
                    "content": {"content_type": "text", "parts": ["hello"]},
                    "status": "finished_successfully",
                    "end_turn": None,
                    "metadata": {},
                },
            },
            "a1": {
                "id": "a1",
                "parent": "u1",
                "children": [],
                "message": {
                    "id": "m-a1",
                    "author": {"role": "assistant"},
                    "content": {"content_type": "text", "parts": ["old branch"]},
                    "status": "finished_successfully",
                    "end_turn": True,
                    "metadata": {},
                },
            },
            "a2": {
                "id": "a2",
                "parent": "u1",
                "children": [],
                "message": {
                    "id": "m-a2",
                    "author": {"role": "assistant"},
                    "content": {
                        "content_type": "multimodal_text",
                        "parts": [
                            "new branch",
                            {
                                "content_type": "image_asset_pointer",
                                "asset_pointer": "sediment://file_abc",
                                "mime_type": "image/png",
                                "width": 512,
                                "height": 512,
                            },
                        ],
                    },
                    "status": "finished_successfully",
                    "end_turn": True,
                    "metadata": {
                        "citations": [
                            {
                                "url": "https://example.com/source",
                                "title": "Source",
                                "text": "Evidence",
                            }
                        ]
                    },
                },
            },
        },
    }


def test_current_branch_uses_current_node_and_parent_links():
    raw = _conversation()
    assert current_branch_ids(raw["mapping"], raw["current_node"]) == ["root", "u1", "a2"]


def test_normalize_preserves_tree_and_only_renders_active_branch():
    data = normalize_conversation(_conversation())

    assert data["id"] == "conv-1"
    assert [message["text"] for message in data["messages"]] == ["hello", "new branch"]
    assert data["tree"]["u1"]["children"] == ["a1", "a2"]


def test_normalize_emits_image_and_citation_blocks():
    data = normalize_conversation(_conversation())
    assistant = data["messages"][-1]

    image = next(block for block in assistant["blocks"] if block["type"] == "image")
    assert image["asset_pointer"] == "sediment://file_abc"
    assert image["mime_type"] == "image/png"

    citations = next(block for block in assistant["blocks"] if block["type"] == "citations")
    assert citations["items"][0]["url"] == "https://example.com/source"


def test_normalize_drops_large_opaque_metadata():
    raw = _conversation()
    raw["mapping"]["a2"]["message"]["metadata"] = {
        "status": "finished",
        "huge_internal_payload": "x" * 100_000,
    }

    data = normalize_conversation(raw)

    assert data["messages"][-1]["metadata"] == {"status": "finished"}
    assert "huge_internal_payload" not in str(data)


def test_normalize_limits_initial_transcript_size():
    raw = {"id": "large", "current_node": "n200", "mapping": {}}
    previous = None
    for index in range(201):
        node_id = f"n{index}"
        raw["mapping"][node_id] = {
            "id": node_id,
            "parent": previous,
            "children": [f"n{index + 1}"] if index < 200 else [],
            "message": {
                "id": f"m{index}",
                "author": {"role": "user"},
                "content": {"content_type": "text", "parts": [str(index)]},
                "metadata": {},
            },
        }
        previous = node_id

    data = normalize_conversation(raw)

    assert len(data["messages"]) == 200
    assert data["messages"][0]["text"] == "1"
    assert data["messages_truncated"] is True
    assert data["messages_omitted"] == 1
