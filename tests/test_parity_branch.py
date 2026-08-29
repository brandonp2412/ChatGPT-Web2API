import pytest

from sloppa.parity_branch import branch_switch_plan
from sloppa.parity_browser import ParityBrowserError


def _mapping():
    return {
        "root": {"parent": None, "children": ["u1"]},
        "u1": {"parent": "root", "children": ["a1", "a2", "a3"]},
        "a1": {"parent": "u1", "children": []},
        "a2": {"parent": "u1", "children": ["u2"]},
        "u2": {"parent": "a2", "children": ["a4"]},
        "a4": {"parent": "u2", "children": []},
        "a3": {"parent": "u1", "children": []},
    }


def test_branch_plan_moves_between_regenerated_siblings():
    plan = branch_switch_plan(_mapping(), "a1", "a3")

    assert plan["divergence_parent"] == "u1"
    assert plan["siblings"] == ["a1", "a2", "a3"]
    assert plan["current_index"] == 0
    assert plan["target_index"] == 2
    assert plan["steps"] == 2


def test_branch_plan_switches_at_first_divergence_for_deep_target():
    plan = branch_switch_plan(_mapping(), "a1", "a4")

    assert plan["divergence_parent"] == "u1"
    assert plan["target_index"] == 1
    assert plan["steps"] == 1


def test_branch_plan_needs_no_pager_when_target_is_active_ancestor():
    plan = branch_switch_plan(_mapping(), "a4", "a2")

    assert plan["steps"] == 0


def test_branch_plan_rejects_unknown_target():
    with pytest.raises(ParityBrowserError):
        branch_switch_plan(_mapping(), "a1", "missing")
