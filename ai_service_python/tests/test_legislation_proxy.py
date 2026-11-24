"""Source patches actually run in new processes and survive session restart."""
import difflib
import json
import threading

import pytest

from brain.cabinet.runtime import CabinetRuntime
from brain.legislation.checkpoint import restore_checkpoint
from brain.legislation.proxy import LegislativeRuntime
from brain.multi_agent.scheduler import MultiAgentService, SessionError
from protocol.models import ChatCompletionResponse
from test_legislation_planning import reading
from test_multi_agent_runtime import frame, accept
from test_multi_agent_scheduler import wait_idle


def request(seq, orders=("木材低于200开始优先采集，到320停止",), **kwargs):
    req = frame(seq, **kwargs)
    req.metadata = req.metadata.model_copy(update={"protocol_version": 3, "match_id": "legislation",
        "session_epoch": "epoch-1", "observation_seq": seq, "backend": "rules_compat"})
    req.observation.player_instructions = list(orders)
    return req


def source_patch(proxy, injection):
    name = "brain/cabinet/departments/economy.py"
    old = (proxy.store.path(proxy.release) / name).read_text(encoding="utf-8")
    new = old.replace("    def act(self, f) -> None:\n", "    def act(self, f) -> None:\n" + injection)
    return {"proposal_id": "order-1", "base_release": proxy.release,
        "unified_diff": "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                                 fromfile="a/"+name, tofile="b/"+name)),
        "state_fields": [{"department": "economy", "name": "wood_priority", "type": "bool", "default": False}],
        "explanation": "wood priority hysteresis"}


@pytest.fixture
def service(tmp_path):
    factory = lambda profile: LegislativeRuntime(profile, root=tmp_path / "data", mode="local-development", timeout=15)
    svc = MultiAgentService(runtime_factory=factory)
    yield svc, factory
    svc.shutdown()


def prepare(svc, injection):
    first = svc.tick(request(1))
    proxy = next(iter(svc._sessions.values())).runtime
    proxy.planning_brief("premier_orders")
    assert proxy.apply_plan("premier_orders", reading())
    brief = proxy.planning_brief("legislative_council")
    assert brief["schema"]["properties"]["base_release"]["const"] == proxy.release
    assert proxy.apply_plan("legislative_council", source_patch(proxy, injection))
    proxy._job.result(timeout=30)
    assert proxy._candidate is not None, proxy._journal
    return proxy, first


HYSTERESIS = """        if f.obs.economy.wood < 200:
            self.wood_priority = True
        elif f.obs.economy.wood >= 320:
            self.wood_priority = False
        if getattr(self, 'wood_priority', False):
            self.boosts['wood'] = BOOST_RUSH
"""

ECONOMY = "brain/cabinet/departments/economy.py"
ACT = "    def act(self, f) -> None:\n"


def begin_coding(svc):
    first = svc.tick(request(1))
    proxy = next(iter(svc._sessions.values())).runtime
    proxy.planning_brief("premier_orders")
    assert proxy.apply_plan("premier_orders", reading())
    assert proxy.planning_brief("legislative_council")["tool_name"] == "legislative_step"
    return proxy, first


def coding_step(proxy, action, **kwargs):
    context = proxy.planning_brief("legislative_council")["context"]
    result = {"proposal_id": context["legislation"]["proposal_id"], "base_release": context["base_release"],
              "step": context["step"], "action": action, **kwargs}
    return proxy.apply_plan("legislative_council", result)


def edit_act(proxy, injection):
    source = proxy._coding._source(ECONOMY)
    line = source[:source.index(ACT)].count("\n") + 1
    assert coding_step(proxy, "read", path=ECONOMY, start_line=line, max_lines=12)
    view = proxy._coding.data["feedback"]
    assert coding_step(proxy, "edit", path=ECONOMY, sha256=view["sha256"],
                       old_text=ACT, new_text=ACT + injection, note="edited wood hysteresis; next validate")


def finish_coding(proxy, fields=None):
    assert coding_step(proxy, "finish", state_fields=fields or [], explanation="department behavior update")
    proxy._job.result(timeout=30)


def test_patch_handoff_hysteresis_retries_restart_and_revocation(service):
    svc, factory = service
    proxy, first = prepare(svc, HYSTERESIS)
    original_pid = proxy.worker.process.pid
    previous = first
    for seq, wood, expected in [(2, 199, True), (3, 250, True), (4, 320, False), (5, 250, False)]:
        req = request(seq, events=accept(previous, seq=seq*100))
        req.observation.economy.wood = wood
        previous = svc.tick(req)
        assert proxy.release != proxy.base
        state = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
        assert state.economy.wood_priority is expected
        assert svc.tick(req) == previous
    assert proxy.worker.process.pid != original_pid
    svc.shutdown()
    restarted = MultiAgentService(runtime_factory=factory)
    try:
        assert restarted.tick(req) == previous
        restored = next(iter(restarted._sessions.values())).runtime
        assert restored.release == proxy.release
        result = restarted.tick(request(6, orders=(), events=accept(previous, seq=600)))
        assert restored.release == restored.base
        assert result["acknowledged_observation_seq"] == 6
        conflict = req.model_copy(deep=True)
        conflict.observation.economy.wood += 1
        with pytest.raises(SessionError, match="observation_seq_conflict"):
            restarted.tick(conflict)
    finally:
        restarted.shutdown()


def test_first_candidate_tick_failure_uses_original_process(service):
    svc, _ = service
    proxy, first = prepare(svc, "        raise RuntimeError('candidate fails')\n")
    pid = proxy.worker.process.pid
    result = svc.tick(request(2, events=accept(first, seq=200)))
    assert proxy.worker.process.pid == pid
    assert proxy.release == proxy.base
    assert result["acknowledged_observation_seq"] == 2


def test_failure_after_install_restores_latest_state(service):
    svc, _ = service
    proxy, first = prepare(svc, "        if f.req.metadata.tick >= 3:\n            raise RuntimeError('late failure')\n" + HYSTERESIS)
    second = svc.tick(request(2, events=accept(first, seq=200)))
    assert proxy.release != proxy.base
    third = svc.tick(request(3, events=accept(second, seq=300)))
    assert proxy.release == proxy.base
    state = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
    assert state.field.last_tick == 3
    assert state.field.kernel._last_event_seq >= 300
    assert svc.tick(request(3, events=accept(second, seq=300))) == third


def test_changed_instruction_discards_ready_candidate(service):
    svc, _ = service
    proxy, first = prepare(svc, HYSTERESIS)
    candidate = proxy._candidate[1]
    svc.tick(request(2, orders=(), events=accept(first, seq=200)))
    assert proxy.release == proxy.base
    assert candidate.process.poll() is not None


def test_two_sessions_keep_independent_active_versions(service):
    svc, _ = service
    proxy, first = prepare(svc, HYSTERESIS)
    other = request(1)
    other.metadata = other.metadata.model_copy(update={"match_id": "other-match"})
    svc.tick(other)
    second_proxy = svc._sessions[("other-match", other.metadata.team)].runtime
    svc.tick(request(2, events=accept(first, seq=200)))
    assert proxy.release != proxy.base
    assert second_proxy.release == second_proxy.base
    assert second_proxy.identity != proxy.identity


def test_two_department_patch_import_failure_installs_neither(service):
    svc, _ = service
    first = svc.tick(request(1))
    proxy = next(iter(svc._sessions.values())).runtime
    proxy.planning_brief("premier_orders")
    assert proxy.apply_plan("premier_orders", reading())
    proxy.planning_brief("legislative_council")
    proposal = source_patch(proxy, HYSTERESIS)
    name = "brain/cabinet/departments/general.py"
    old = (proxy.store.path(proxy.release) / name).read_text(encoding="utf-8")
    new = old + "\nraise RuntimeError('invalid general import')\n"
    proposal["unified_diff"] += "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                                             fromfile="a/"+name, tofile="b/"+name))
    assert proxy.apply_plan("legislative_council", proposal)
    proxy._job.result(timeout=30)
    assert proxy._candidate is None
    assert proxy._failed
    svc.tick(request(2, events=accept(first, seq=200)))
    assert proxy.release == proxy.base
    state = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
    assert not hasattr(state.economy, "wood_priority")
    assert state.ledger.orders[0].legislation["status"] == "failed"


@pytest.mark.parametrize("parallel_reads", [False, True])
def test_scheduler_routes_mock_model_source_proposal(tmp_path, monkeypatch, parallel_reads):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    calls = []
    steps = []
    holder = {}
    def forward(req):
        role = req.metadata.agent
        calls.append(role)
        if role == "premier_orders":
            result = reading()
        elif role == "legislative_council":
            assert req.tool_choice == "auto"
            assert {tool.function.name for tool in req.tools} == {
                "legislative_" + name for name in ("list", "search", "read", "edit", "finish", "blocked")}
            context = json.loads(req.messages[1].content)
            result = {"proposal_id": context["legislation"]["proposal_id"],
                      "base_release": context["base_release"], "step": context["step"]}
            step = context["step"]
            if step == 0:
                result.update(action="list", path="brain/cabinet/departments/")
            elif step == 1:
                assert ECONOMY in context["last_result"]["files"]
                result.update(action="search", path=ECONOMY, query="def act(")
            elif step == 2:
                found = context["last_result"]["matches"][0]
                if parallel_reads:
                    assert context["last_result"]["tool_selection"]["selected_call"] == 2
                result.update(action="read", path=found["path"], start_line=found["line"], max_lines=12)
            elif step == 3:
                view = context["last_result"]
                assert ACT in view["text"]
                if parallel_reads:
                    assert view["tool_selection"]["selected_call"] == 2
                    assert view["tool_selection"]["unexecuted_calls"] == [1]
                result.update(action="edit", path=ECONOMY, sha256=view["sha256"],
                              old_text=ACT, new_text=ACT + HYSTERESIS)
            else:
                assert step == 4
                result.update(action="finish", state_fields=source_patch(holder["proxy"], "")["state_fields"],
                              explanation="wood hysteresis implemented and ready for validation")
            steps.append(result["action"])
            result["note"] = "Inspect call contract, make the minimal change, then submit for validation."
        else:
            result = {}  # Ranking rejection leaves the ordinary rule fallback intact.
        tool_name = "legislative_" + result["action"] if role == "legislative_council" else req.tools[0].function.name
        arguments = {k: v for k, v in result.items() if k not in {"proposal_id", "base_release", "step", "action"}} if role == "legislative_council" else result
        raw = {"id": "mock", "choices": [{"finish_reason": "tool_calls", "message": {
            "role": "assistant", "tool_calls": [{"type": "function", "function": {
                "name": tool_name, "arguments": json.dumps(arguments)}}]}}]}
        if parallel_reads and role == "legislative_council" and step in (1, 2):
            raw["choices"][0]["message"]["tool_calls"].insert(0, {"type": "function", "function": {
                "name": "legislative_list", "arguments": json.dumps({"note": "List source files"})}})
        return ChatCompletionResponse.model_validate(raw), {}, raw
    def factory(profile):
        holder["proxy"] = LegislativeRuntime(profile, root=tmp_path / "store", mode="local-development", timeout=15)
        return holder["proxy"]
    svc = MultiAgentService(runtime_factory=factory, forward=forward, calls_per_minute=60)
    try:
        previous = None
        for seq in range(1, 12):
            req = request(seq, events=accept(previous, seq=seq*100) if previous else [])
            req.metadata = req.metadata.model_copy(update={"backend": "openai"})
            previous = svc.tick(req)
            wait_idle(svc)
            proxy = holder["proxy"]
            if proxy._job:
                proxy._job.result(timeout=30)
                break
        else:
            pytest.fail(f"coding agent never submitted a candidate: {calls}, {proxy._journal}")
        assert steps == ["list", "search", "read", "edit", "finish"]
        assert proxy.release == proxy.base
        svc.tick(request(seq + 1, events=accept(previous, seq=(seq + 1)*100)))
        assert proxy.release != proxy.base, proxy._journal
        assert proxy._coding.status == "installed"
        state = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
        assert state.ledger.orders[0].legislation["status"] == "installed"
    finally:
        svc.shutdown()


@pytest.mark.parametrize("ready", [False, True])
def test_coding_draft_survives_service_restart_and_installs(service, ready):
    svc, factory = service
    proxy, first = begin_coding(svc)
    edit_act(proxy, HYSTERESIS)
    if ready:
        finish_coding(proxy, source_patch(proxy, "")["state_fields"])
        assert proxy._candidate is not None
    snapshot = proxy._coding.snapshot()
    assert proxy.release == proxy.base
    svc.shutdown()
    restarted = MultiAgentService(runtime_factory=factory)
    try:
        assert restarted.tick(request(1)) == first
        restored = next(iter(restarted._sessions.values())).runtime
        if ready:
            assert restored._coding.status == "coding"
            assert restored._coding.data["drafts"] == snapshot["data"]["drafts"]
        else:
            assert restored._coding.snapshot() == snapshot
        brief = restored.planning_brief("legislative_council")
        assert brief["context"]["step"] == (3 if ready else 2)
        assert brief["context"]["note"] == "edited wood hysteresis; next validate"
        finish_coding(restored, source_patch(restored, "")["state_fields"])
        assert restored._candidate is not None
        restarted.tick(request(2, events=accept(first, seq=200)))
        assert restored.release != restored.base
    finally:
        restarted.shutdown()


def test_candidate_import_error_returns_to_agent_for_repair(service):
    svc, _ = service
    proxy, first = begin_coding(svc)
    anchor = "from __future__ import annotations\n"
    invalid = "raise RuntimeError('candidate import failed')\n"
    assert coding_step(proxy, "read", path=ECONOMY, start_line=1, max_lines=30)
    assert coding_step(proxy, "edit", path=ECONOMY, sha256=proxy._coding.data["feedback"]["sha256"],
                       old_text=anchor, new_text=anchor + invalid)
    finish_coding(proxy)
    assert proxy._candidate is None and not proxy._failed
    assert proxy._coding.status == "coding"
    brief = proxy.planning_brief("legislative_council")
    assert "candidate_validation_failed" in brief["context"]["last_error"]["error"]
    state = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
    assert state.ledger.orders[0].legislation["status"] == "waiting"
    assert state.ledger.orders[0].legislation["phase"] == "retrying"
    assert coding_step(proxy, "read", path=ECONOMY, start_line=1, max_lines=30)
    assert coding_step(proxy, "edit", path=ECONOMY, sha256=proxy._coding.data["feedback"]["sha256"],
                       old_text=invalid, new_text="# validated candidate import\n")
    finish_coding(proxy)
    assert proxy._candidate is not None
    svc.tick(request(2, events=accept(first, seq=200)))
    assert proxy.release != proxy.base


def test_candidate_tick_error_preserves_live_state_and_can_be_repaired(service):
    svc, _ = service
    proxy, first = begin_coding(svc)
    invalid = "        raise RuntimeError('candidate tick failed')\n"
    edit_act(proxy, invalid)
    finish_coding(proxy)
    original_pid = proxy.worker.process.pid
    req = request(2, events=accept(first, seq=200))
    second = svc.tick(req)
    assert proxy.release == proxy.base
    assert proxy.worker.process.pid == original_pid
    assert proxy._coding.status == "coding"
    assert "candidate_tick_failed" in proxy._coding.data["feedback"]["error"]
    assert svc.tick(req) == second
    current = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
    assert current.field.last_tick == 2
    assert current.ledger.orders[0].legislation["status"] == "waiting"
    source = proxy._coding._source(ECONOMY)
    line = source[:source.index(ACT)].count("\n") + 1
    assert coding_step(proxy, "read", path=ECONOMY, start_line=line, max_lines=12)
    assert coding_step(proxy, "edit", path=ECONOMY, sha256=proxy._coding.data["feedback"]["sha256"],
                       old_text=invalid, new_text=HYSTERESIS)
    finish_coding(proxy, source_patch(proxy, "")["state_fields"])
    svc.tick(request(3, events=accept(second, seq=300)))
    assert proxy.release != proxy.base
    assert restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile)).field.last_tick == 3


def test_agent_blocked_capability_is_visible_and_not_resubmitted(service):
    svc, _ = service
    proxy, first = begin_coding(svc)
    assert coding_step(proxy, "blocked", explanation="Game does not expose adjacent legal farm candidates.")
    assert proxy.planning_brief("legislative_council") is None
    assert proxy._job is None and proxy._coding.status == "blocked"
    result = svc.tick(request(2, events=accept(first, seq=200)))
    assert result["planning"]["legislation"]["phase"] == "blocked"
    state = restore_checkpoint(proxy.state, CabinetRuntime(proxy.profile))
    order = state.ledger.orders[0]
    assert order.legislation["status"] == "failed"
    assert "adjacent legal farm candidates" in order.waiting


def test_changed_instruction_cancels_inflight_build_even_if_text_returns(service, monkeypatch):
    svc, _ = service
    proxy, first = begin_coding(svc)
    edit_act(proxy, HYSTERESIS)
    entered, release = threading.Event(), threading.Event()
    build = proxy.store.build

    def delayed_build(*args):
        entered.set()
        assert release.wait(20)
        return build(*args)

    monkeypatch.setattr(proxy.store, "build", delayed_build)
    assert coding_step(proxy, "finish", state_fields=source_patch(proxy, "")["state_fields"], explanation="hysteresis")
    assert entered.wait(5)
    try:
        second = svc.tick(request(2, orders=(), events=accept(first, seq=200)))
        svc.tick(request(3, events=accept(second, seq=300)))
        assert proxy._coding is None
    finally:
        release.set()
        proxy._job.result(timeout=30)
    assert proxy._candidate is None and not proxy._failed
    assert proxy.release == proxy.base
