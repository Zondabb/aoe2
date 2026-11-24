"""Bounded coding turns preserve the goal and can only submit inspected edits."""
from __future__ import annotations

import copy
import json

from jsonschema import Draft202012Validator, ValidationError
import pytest

from brain import runtime_settings
from brain.legislation.agent import CodingSession, byte_size, digest
from brain.legislation.planning import proposal_schema
from brain.legislation.releases import WRITABLE, apply_diff


ECONOMY = "brain/cabinet/departments/economy.py"
CALLER = "brain/cabinet/runtime.py"
SOURCE = "def choose():\n    return 1\n"


@pytest.fixture
def make_session(tmp_path, monkeypatch):
    monkeypatch.setattr(runtime_settings, "legislation_context_tokens", lambda: 16384)
    monkeypatch.setattr(runtime_settings, "legislation_max_steps", lambda: 24)
    count = 0

    def make(sources=None, requirement=None):
        nonlocal count
        count += 1
        root = tmp_path / str(count)
        files = {path: SOURCE for path in WRITABLE}
        files[CALLER] = "# caller is readable, but is not editable\n"
        files.update(sources or {})
        for path, text in files.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")

        class Store:
            def path(self, release):
                assert release == "a" * 64
                return root

            def manifest(self, release):
                assert release == "a" * 64
                return {"files": files}

        goal = requirement or {"proposal_id": "order-1", "instruction": "Keep the original economic goal",
                               "departments": ["economy"], "evidence": ["A stateful choice is missing"],
                               "acceptance": {"positive": ["choose 2"], "negative": ["choose 1"]}}
        return CodingSession(Store(), goal, "a" * 64)

    return make


def action(session, operation, **fields):
    return {"proposal_id": session.requirement["proposal_id"], "base_release": session.base,
            "step": session.data["steps"], "action": operation, **fields}


def read(session, path=ECONOMY, **fields):
    session.apply(action(session, "read", path=path, start_line=1, **fields))
    return copy.deepcopy(session.data["feedback"])


def edit(session, view, old="return 1", new="return 2", **fields):
    return session.apply(action(session, "edit", path=view["path"], sha256=view["sha256"],
                                old_text=old, new_text=new, **fields))


def test_read_edit_finish_builds_an_exact_patch_without_touching_the_release(make_session):
    session = make_session()
    view = read(session)
    assert view["sha256"] == digest(SOURCE)
    assert edit(session, view, note="Changed choice; submit for isolated checks.") is None
    assert (session.root / ECONOMY).read_text(encoding="utf-8") == SOURCE
    assert session.data["drafts"][ECONOMY] == SOURCE.replace("return 1", "return 2")
    fields = [{"department": "economy", "name": "choice", "type": "int", "default": 1}]
    proposal = session.apply(action(session, "finish", state_fields=fields, explanation="Preserve economic state"))
    Draft202012Validator(proposal_schema("order-1", session.base)).validate(proposal)
    assert apply_diff({ECONOMY: SOURCE}, proposal["unified_diff"]) == session.data["drafts"]
    assert proposal["state_fields"] == fields and session.status == "validating"
    assert "not installed yet" in session.data["feedback"]["message"]
    with pytest.raises(ValueError, match="not_ready"):
        session.apply(action(session, "list"))


@pytest.mark.parametrize("output_limit", [2048, 8192])
def test_context_stays_bounded_with_large_chinese_source_and_repeated_reads(make_session, monkeypatch, output_limit):
    monkeypatch.setattr(runtime_settings, "legislation_output_tokens", lambda: output_limit)
    huge = "".join("# 这是经济部门的一条很长的源码注释。" * 20 + "\n" for _ in range(2000))
    session = make_session({ECONOMY: huge})
    for start in range(1, 10):
        session.apply(action(session, "read", path=ECONOMY, start_line=start, max_lines=120,
                             note="Read another bounded section."))
        brief = session.brief()
        assert session.data["feedback"]["truncated"]
        assert len(session.data["feedback"]["text"].encode("utf-8")) <= 2000
        used = byte_size(brief["context"]) + byte_size(brief["tools"]) + len(brief["system"].encode("utf-8"))
        assert used + brief["output_tokens"] + 1024 <= 16384
        assert brief["context"]["legislation"] == session.requirement
        assert "text" in brief["context"]["last_result"]
        assert "history" not in brief["context"] and "drafts" not in brief["context"]
        assert len(json.dumps(brief, ensure_ascii=False)) < 12000


def test_oversized_feedback_is_replaced_but_oversized_goal_is_never_silently_truncated(make_session):
    session = make_session()
    session.data["feedback"] = {"text": "源码" * 30000}
    assert session.brief()["context"]["last_result"]["error"] == "previous_result_exceeds_context_budget"
    session.requirement["instruction"] = "冻结的目标" * 30000
    original = copy.deepcopy(session.requirement)
    with pytest.raises(ValueError, match="requirement_exceeds_context_budget"):
        session.brief()
    assert session.requirement == original and not session.data["drafts"]


@pytest.mark.parametrize("output_limit", [2048, 4096])
def test_minimum_context_configuration_is_bounded_or_explicitly_refused(make_session, monkeypatch, output_limit):
    monkeypatch.setattr(runtime_settings, "legislation_context_tokens", lambda: 8192)
    monkeypatch.setattr(runtime_settings, "legislation_output_tokens", lambda: output_limit)
    session = make_session()
    original = copy.deepcopy(session.requirement)
    try:
        brief = session.brief()
    except ValueError as exc:
        assert str(exc) == "legislation_requirement_exceeds_context_budget"
    else:
        used = byte_size(brief["context"]) + byte_size(brief["tools"]) + len(brief["system"].encode("utf-8"))
        assert used + output_limit + 1024 <= 8192
        assert brief["context"]["legislation"] == original
    assert session.requirement == original


def test_eight_k_context_keeps_room_for_the_goal_and_a_real_source_read(make_session, monkeypatch):
    monkeypatch.setattr(runtime_settings, "legislation_context_tokens", lambda: 8192)
    session = make_session({ECONOMY: "# 经济部门\n" * 500})
    view = read(session, max_lines=120)
    brief = session.brief()
    assert brief["output_tokens"] == 1024
    assert brief["context"]["last_result"]["text"]
    assert view["text"].startswith(brief["context"]["last_result"]["text"])
    assert session.data["view"]["text"] == brief["context"]["last_result"]["text"]
    assert brief["context"]["legislation"] == session.requirement
    used = byte_size(brief["context"]) + byte_size(brief["tools"]) + len(brief["system"].encode("utf-8"))
    assert used + brief["output_tokens"] + 1024 <= 8192


def test_terminal_progress_can_retry_after_the_worker_rpc_fails(make_session):
    from brain.legislation.proxy import LegislativeRuntime
    proxy = object.__new__(LegislativeRuntime)
    proxy._coding = make_session()
    proxy._coding.data.update(status="failed", feedback={"error": "coding_step_limit"})
    proxy._progress_key = None
    calls = []

    def report(*args):
        calls.append(args)
        if len(calls) == 1:
            raise RuntimeError("worker unavailable")
        return True

    proxy._call = report
    with pytest.raises(RuntimeError, match="worker unavailable"):
        proxy._coding_progress()
    assert not proxy._coding.data.get("reported")
    proxy._coding_progress()
    assert proxy._coding.data["reported"] and len(calls) == 2


def test_list_and_search_page_results_and_can_inspect_read_only_callers(make_session):
    files = {f"brain/cabinet/support_{i:02}.py": "# needle\n" * 2 for i in range(30)}
    session = make_session(files)
    session.apply(action(session, "list", path="brain/cabinet/support_"))
    first = copy.deepcopy(session.data["feedback"])
    assert len(first["files"]) == 20 and first["total"] == 30
    session.apply(action(session, "list", path="brain/cabinet/support_", offset=first["next_offset"]))
    assert len(session.data["feedback"]["files"]) == 10
    assert not set(first["files"]) & set(session.data["feedback"]["files"])
    session.apply(action(session, "search", path="brain/cabinet/support_", query="needle"))
    first = copy.deepcopy(session.data["feedback"])
    assert len(first["matches"]) == 8
    session.apply(action(session, "search", path="brain/cabinet/support_", query="needle", offset=first["next_offset"]))
    assert len(session.data["feedback"]["matches"]) == 8
    assert first["matches"] != session.data["feedback"]["matches"]
    view = read(session, CALLER)
    assert "readable" in view["text"]
    edit(session, view, old="readable", new="changed")
    assert session.data["feedback"]["error"] == "edit_path_not_allowed"
    assert not session.data["drafts"]


@pytest.mark.parametrize("path", ["../secret.py", "C:/secret.py", "brain/cabinet/../../secret.py",
                                  "brain\\cabinet\\departments\\economy.py", "missing.py"])
def test_paths_outside_manifest_are_rejected(make_session, path):
    session = make_session()
    session.apply(action(session, "read", path=path, start_line=1))
    assert session.data["feedback"]["error"] == "source_path_not_allowed"
    assert session.data["view"] is None and not session.data["drafts"]


@pytest.mark.parametrize("change", ["without_read", "wrong_hash", "unseen_text", "different_file", "reused_view"])
def test_edit_requires_current_hash_and_the_exact_recently_read_text(make_session, change):
    session = make_session({ECONOMY: SOURCE + "UNSEEN = 1\n"})
    view = {"path": ECONOMY, "sha256": digest(SOURCE + "UNSEEN = 1\n")}
    old = "return 1"
    if change != "without_read":
        view = read(session, max_lines=2)
    if change == "wrong_hash":
        view["sha256"] = "0" * 64
    elif change == "unseen_text":
        old = "UNSEEN = 1"
    elif change == "different_file":
        read(session, CALLER)
    elif change == "reused_view":
        edit(session, view)
    before = copy.deepcopy(session.data["drafts"])
    edit(session, view, old=old)
    assert session.data["feedback"]["error"] == "edit_requires_current_read"
    assert session.data["drafts"] == before


def test_ambiguous_replacement_and_syntax_error_leave_source_unchanged(make_session):
    duplicate = make_session({ECONOMY: "VALUE = 1\nVALUE = 1\n"})
    edit(duplicate, read(duplicate), old="VALUE = 1", new="VALUE = 2")
    assert duplicate.data["feedback"]["error"] == "edit_old_text_not_unique"
    assert not duplicate.data["drafts"]
    invalid = make_session()
    edit(invalid, read(invalid), new="return (")
    assert invalid.data["failures"] == 1 and not invalid.data["drafts"]
    assert (invalid.root / ECONOMY).read_text(encoding="utf-8") == SOURCE


@pytest.mark.parametrize("changed", [{"proposal_id": "other"}, {"base_release": "b" * 64}, {"step": 10},
                                     {"shell": "echo unauthorized"}, {"max_lines": 121}, {"note": "x" * 401}])
def test_tool_schema_rejects_wrong_identity_stale_steps_and_excessive_arguments(make_session, changed):
    session = make_session()
    before = copy.deepcopy(session.snapshot())
    with pytest.raises(ValidationError):
        session.apply({**action(session, "read", path=ECONOMY, start_line=1), **changed})
    assert session.snapshot() == before


def test_step_limit_ends_unproductive_session_without_proposal(make_session, monkeypatch):
    monkeypatch.setattr(runtime_settings, "legislation_max_steps", lambda: 4)
    session = make_session()
    for _ in range(4):
        assert session.apply(action(session, "list")) is None
    assert session.status == "failed" and session.data["feedback"]["error"] == "coding_step_limit"
    with pytest.raises(ValueError, match="not_ready"):
        session.apply(action(session, "list"))
    assert not session.data["drafts"]


def test_snapshot_round_trip_resumes_draft_view_and_goal_in_a_fresh_session(make_session):
    session = make_session()
    edit(session, read(session), note="One change made; inspect it before finishing.")
    read(session)
    frozen = json.loads(json.dumps(session.snapshot()))
    restored = CodingSession(session.store, frozen["requirement"], frozen["base_release"], saved=frozen["data"])
    assert restored.brief() == session.brief()
    edit(restored, restored.data["view"], old="return 2", new="return 3")
    assert "return 3" in restored.data["drafts"][ECONOMY]
    assert "return 2" in session.data["drafts"][ECONOMY]
    assert frozen["data"] == session.data  # restoring and resuming did not mutate the persisted snapshot
    proposal = restored.apply(action(restored, "finish", state_fields=[], explanation="Reviewed both changes"))
    assert "return 3" in apply_diff({ECONOMY: SOURCE}, proposal["unified_diff"])[ECONOMY]


def test_snapshot_and_constructor_inputs_are_detached_from_the_active_session(make_session):
    requirement = {"proposal_id": "order-1", "instruction": "Keep the target", "acceptance": ["original"]}
    session = make_session(requirement=requirement)
    requirement["acceptance"].append("external mutation")
    saved = session.snapshot()
    edit(session, read(session))
    assert saved["data"]["steps"] == 0 and not saved["data"]["drafts"]
    saved["requirement"]["acceptance"].clear()
    assert session.requirement["acceptance"] == ["original"]


def test_finish_without_a_change_is_a_retryable_rejection_not_a_candidate(make_session):
    session = make_session()
    assert session.apply(action(session, "finish", state_fields=[], explanation="No change needed")) is None
    assert session.status == "coding" and session.data["failures"] == 1
    assert "error" in session.data["feedback"] and not session.data["drafts"]


def test_truncated_or_invalid_response_does_not_apply_partial_edit_and_retries_are_finite(make_session):
    session = make_session()
    view = read(session)
    partial = action(session, "edit", path=ECONOMY, sha256=view["sha256"], old_text="return 1")
    with pytest.raises(ValidationError):
        session.apply(partial)
    original = copy.deepcopy(session.requirement)
    for reason in ("truncated_response", "invalid_tool_arguments", "model_timeout"):
        session.reject(reason)
        assert not session.data["drafts"] and session.requirement == original
        assert session.data["feedback"]["error"] == reason
    assert session.status == "failed" and session.data["failures"] == 3


def test_successful_smaller_operation_after_rejection_preserves_goal_and_resets_failure_streak(make_session):
    session = make_session()
    original = copy.deepcopy(session.requirement)
    session.reject("truncated_response")
    assert "original goal is unchanged" in session.brief()["context"]["last_error"]["hint"]
    edit(session, read(session, max_lines=2))
    assert session.status == "coding" and session.data["failures"] == 0
    assert session.requirement == original


def test_invalid_multi_call_keeps_the_successful_read_and_edit_view_across_restart(make_session):
    session = make_session()
    view = read(session)
    session.reject("invalid_tool_calls: received 2 calls")
    context = session.brief()["context"]
    assert context["last_result"] == view
    assert "exactly ONE" in context["last_error"]["hint"]
    saved = session.snapshot()
    restored = CodingSession(session.store, saved["requirement"], saved["base_release"], saved["data"])
    assert restored.brief()["context"] == context
    edit(restored, view)
    assert not restored.data["failures"] and "return 2" in restored.data["drafts"][ECONOMY]
    assert "last_error" not in restored.brief()["context"]


def test_missing_game_capability_is_reported_without_a_patch_or_success_claim(make_session):
    session = make_session()
    result = session.apply(action(session, "blocked", explanation="The game exposes no adjoining placement candidates."))
    assert result is None and session.status == "blocked" and not session.data["drafts"]
    assert "placement candidates" in session.data["feedback"]["reason"]
    with pytest.raises(ValueError, match="not_ready"):
        session.apply(action(session, "list"))


def test_active_source_map_and_search_precede_legacy_farm_implementation(make_session):
    active = "brain/multi_agent/runtime.py"
    legacy = "brain/build_placement.py"
    session = make_session({active: "def _building_sites():\n    return 'farm'\n",
                            legacy: "# farm legacy path\n" * 100})
    session.apply(action(session, "search", query="farm"))
    brief = session.brief()
    assert brief["context"]["source_map"][active]["_building_sites"] == 1
    assert brief["context"]["last_result"]["matches"][0]["path"] == active
    assert brief["context"]["last_result"]["query"] == "farm"
    assert brief["context"]["recent_actions"][-1] == {"action": "search", "query": "farm"}


def test_source_read_cursor_and_history_survive_budget_trimming_and_restart(make_session, monkeypatch):
    monkeypatch.setattr(runtime_settings, "legislation_context_tokens", lambda: 8192)
    source = "".join(f"# source row {i} 经济部门函数调用和参数\n" for i in range(300))
    session = make_session({ECONOMY: source})
    read(session, max_lines=120)
    brief = session.brief()
    result = brief["context"]["last_result"]
    assert result["text"] and result["text"].endswith("\n")
    assert result["text"] == "".join(source.splitlines(True)[result["start_line"]-1:result["next_line"]-1])
    assert brief["context"]["recent_actions"][-1]["next_line"] == result["next_line"]
    saved = session.snapshot()
    restored = CodingSession(session.store, saved["requirement"], saved["base_release"], saved["data"])
    assert restored.brief()["context"]["recent_actions"] == brief["context"]["recent_actions"]
    restored.apply(action(restored, "read", path=ECONOMY, start_line=result["next_line"], max_lines=1))
    assert restored.data["feedback"]["text"] == source.splitlines(True)[result["next_line"]-1]


def test_reading_a_file_without_final_newline_advances_past_its_last_line(make_session):
    session = make_session({ECONOMY: "VALUE = 1"})
    assert read(session)["next_line"] == 2


def test_list_rejects_exact_python_file_and_warns_on_duplicate_readonly_step(make_session):
    session = make_session({ECONOMY: "class EconomyDept:\n    def choose_sites(self, f, name, options):\n        return options\n"})
    assert session.brief()["context"]["source_map"][ECONOMY]["choose_sites"] == 2
    assert session.apply(action(session, "list", path=ECONOMY, offset=64)) is None
    assert "list_expects_directory_prefix" in session.data["feedback"]["error"]
    assert session.data["failures"] == 1
    assert session.apply(action(session, "list", path="brain/cabinet/departments/")) is None
    assert "warning" not in session.data["feedback"]
    assert session.apply(action(session, "list", path="brain/cabinet/departments/")) is None
    assert "Repeated identical read-only call" in session.data["feedback"]["warning"]
