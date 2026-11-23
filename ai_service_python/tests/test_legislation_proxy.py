"""Source patches actually run in new processes and survive session restart."""
import difflib
import json

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


def test_scheduler_routes_mock_model_source_proposal(tmp_path, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    calls = []
    holder = {}
    def forward(req):
        role = req.metadata.agent
        calls.append(role)
        if role == "premier_orders":
            result = reading()
        elif role == "legislative_council":
            result = source_patch(holder["proxy"], HYSTERESIS)
        else:
            result = {}  # Ranking rejection leaves the ordinary rule fallback intact.
        raw = {"id": "mock", "choices": [{"finish_reason": "tool_calls", "message": {
            "role": "assistant", "tool_calls": [{"type": "function", "function": {
                "name": req.tools[0].function.name, "arguments": json.dumps(result)}}]}}]}
        return ChatCompletionResponse.model_validate(raw), {}, raw
    def factory(profile):
        holder["proxy"] = LegislativeRuntime(profile, root=tmp_path / "store", mode="local-development", timeout=15)
        return holder["proxy"]
    svc = MultiAgentService(runtime_factory=factory, forward=forward, calls_per_minute=60)
    try:
        req = request(1)
        req.metadata = req.metadata.model_copy(update={"backend": "openai"})
        first = svc.tick(req)
        wait_idle(svc)
        req = request(2, events=accept(first, seq=200))
        req.metadata = req.metadata.model_copy(update={"backend": "openai"})
        second = svc.tick(req)
        wait_idle(svc)
        proxy = holder["proxy"]
        assert "legislative_council" in calls
        proxy._job.result(timeout=30)
        svc.tick(request(3, events=accept(second, seq=300)))
        assert proxy.release != proxy.base, proxy._journal
    finally:
        svc.shutdown()
