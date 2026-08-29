from sloppa.parity_view import normalize_client_conversation


def test_client_view_exposes_visible_sibling_messages_but_not_hidden_content():
    raw = {
        "id": "conv-1",
        "title": "Branches",
        "current_node": "a2",
        "mapping": {
            "root": {
                "parent": None,
                "children": ["u1"],
                "message": None,
            },
            "u1": {
                "parent": "root",
                "children": ["a1", "a2"],
                "message": {
                    "id": "user-1",
                    "author": {"role": "user"},
                    "content": {"content_type": "text", "parts": ["hello"]},
                    "metadata": {},
                },
            },
            "a1": {
                "parent": "u1",
                "children": [],
                "message": {
                    "id": "assistant-old",
                    "author": {"role": "assistant"},
                    "content": {"content_type": "text", "parts": ["old answer"]},
                    "metadata": {},
                },
            },
            "a2": {
                "parent": "u1",
                "children": ["hidden"],
                "message": {
                    "id": "assistant-new",
                    "author": {"role": "assistant"},
                    "content": {"content_type": "text", "parts": ["new answer"]},
                    "metadata": {},
                },
            },
            "hidden": {
                "parent": "a2",
                "children": [],
                "message": {
                    "id": "hidden-context",
                    "author": {"role": "system"},
                    "content": {
                        "content_type": "model_editable_context",
                        "parts": ["private internal context"],
                    },
                    "metadata": {"is_visually_hidden_from_conversation": True},
                },
            },
        },
    }

    view = normalize_client_conversation(raw)

    visible_text = [message.get("text") for message in view["messages"]]
    assert visible_text == ["hello", "new answer"]
    assert view["nodes"]["a1"]["message"]["text"] == "old answer"
    assert view["nodes"]["a2"]["message"]["text"] == "new answer"
    assert view["nodes"]["hidden"]["message"] is None
    assert "private internal context" not in str(view)
