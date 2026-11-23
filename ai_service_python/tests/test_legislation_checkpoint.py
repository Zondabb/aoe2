"""Continuation and rejection tests for process-independent cabinet state."""
import copy
import json

import pytest

from brain.cabinet.runtime import CabinetRuntime
from brain.legislation.checkpoint import CheckpointError, export_checkpoint, restore_checkpoint
from test_multi_agent_runtime import accept, frame


def round_trip(runtime, target=None):
    data = json.loads(json.dumps(export_checkpoint(runtime), allow_nan=False))
    return restore_checkpoint(data, target or CabinetRuntime("chinese"))


def test_shared_objects_and_constructor_defaults_survive():
    original = CabinetRuntime("chinese")
    original.tick(frame(1))
    target = CabinetRuntime("chinese")
    target.economy.wood_priority = False
    clock = lambda: 123.0
    target.voice.clock = clock
    restored = round_trip(original, target)
    assert restored is target
    assert restored.economy.wood_priority is False
    assert restored.voice.clock is clock
    assert restored.field.kernel.listener is restored.field
    assert restored.field.kernel.validator is restored.field.validator
    assert restored.crew.treasury is restored.treasury
    for dept in restored.departments:
        assert dept.field is restored.field
        assert dept.treasury is restored.treasury
        assert dept is getattr(restored, dept.name)
    for request in restored.requests:
        assert request is getattr(restored, request.dept).book[request.key]
    assert restored.field.roles["economy"].events.maxlen == 12


def test_inflight_commands_receipts_and_later_decisions_match_continuous_run():
    continuous = CabinetRuntime("chinese")
    first = continuous.tick(frame(1))
    assert continuous.field.pending
    restored = round_trip(continuous)
    assert restored.field.pending == continuous.field.pending
    assert restored.field.leases == continuous.field.leases
    assert restored.treasury.escrow == continuous.treasury.escrow
    assert restored.tick(frame(1)) == first  # cached response keeps original IDs
    for tick in (2, 3, 4):
        request = frame(tick, events=accept(first, seq=tick * 50))
        expected = continuous.tick(copy.deepcopy(request))
        actual = restored.tick(copy.deepcopy(request))
        assert actual == expected
        assert restored.field.kernel._last_event_seq == continuous.field.kernel._last_event_seq
        assert restored.economy._serial == continuous.economy._serial
        first = expected


def test_planning_after_restore_and_new_private_state_round_trip():
    runtime = CabinetRuntime("chinese")
    runtime.tick(frame(1))
    runtime.economy.wood_priority = True
    restored = round_trip(runtime)
    assert restored.economy.wood_priority is True
    assert restored.planning_context("premier") == runtime.planning_context("premier")
    assert restored.field.frame is not None
    assert restored.field.frame.obs is restored.field.frame.req.observation
    assert restored.field.frame.context is restored.field.frame.req.observation.decision_context


@pytest.mark.parametrize("mutation", [
    lambda data: data.update(version=99),
    lambda data: data["nodes"][0].update(cls="subprocess.Popen"),
    lambda data: data["nodes"][0]["attrs"].update(tick="replace executable"),
    lambda data: data["nodes"][0]["attrs"].update(__class__="replace class"),
    lambda data: data["nodes"][0]["attrs"].update(economy={"ref": 999999}),
    lambda data: data["nodes"][0]["attrs"].update(journal=float("nan")),
    lambda data: data["nodes"].append({"kind": "list", "items": []}),
])
def test_rejects_malformed_or_executable_checkpoints(mutation):
    data = export_checkpoint(CabinetRuntime("chinese"))
    mutation(data)
    with pytest.raises(CheckpointError):
        restore_checkpoint(data, CabinetRuntime("chinese"))


def test_unknown_python_objects_and_excessive_depth_rejected():
    runtime = CabinetRuntime("chinese")
    runtime.economy.injected = object()
    with pytest.raises(CheckpointError, match="unregistered"):
        export_checkpoint(runtime)
    del runtime.economy.injected
    nested = []
    for _ in range(110):
        nested = [nested]
    runtime.economy.injected = nested
    with pytest.raises(CheckpointError, match="depth"):
        export_checkpoint(runtime)


def test_reference_table_cannot_rewire_departments_to_separate_treasuries():
    data = export_checkpoint(CabinetRuntime("chinese"))
    economy = next(node for node in data["nodes"] if node.get("cls", "").endswith(".EconomyDept"))
    economy["attrs"]["treasury"] = economy["attrs"]["field"]
    with pytest.raises(CheckpointError, match="references"):
        restore_checkpoint(data, CabinetRuntime("chinese"))
