"""Tests for batch unit selection, tool mapping, kernel tracking, and runtime combat coalescing."""
from __future__ import annotations

from brain.llm_commander import LlmCommander
from brain.multi_agent.runtime import MultiAgentRuntime
from brain.tool_call_mapper import TOOL_NAMES, command_to_tool_call, tool_call_to_command, tool_definitions
from protocol.models import ChatCompletionChoice, ChatCompletionRequest, ChatCompletionResponse, ChatMessage, Command
from test_llm_commander import building, request, unit
from test_multi_agent_runtime import accept, army, enemy_tc, frame, issued


def test_tool_call_mapper_supports_all_batch_tools():
    batch_names = {"move_group", "move_box", "move_same_type", "attack_group", "attack_box", "attack_same_type"}
    assert batch_names.issubset(set(TOOL_NAMES))
    defs = {item["function"]["name"]: item for item in tool_definitions()}
    assert batch_names.issubset(defs.keys())
    cases = [
        {"op": "move_group", "unit_ids": [30, 31], "pos": [12.0, 14.0], "formation": "line"},
        {"op": "move_box", "box": [-5.0, -5.0, 5.0, 5.0], "pos": [18.0, 18.0], "formation": "box"},
        {"op": "move_same_type", "unit_def_id": "militia", "pos": [20.0, 10.0], "formation": "staggered"},
        {"op": "attack_group", "unit_ids": [30, 31], "target_id": 200},
        {"op": "attack_box", "box": [-5.0, -5.0, 5.0, 5.0], "target_id": 200},
        {"op": "attack_same_type", "unit_def_id": "militia", "target_id": 200},
    ]
    for idx, sample in enumerate(cases):
        cmd = Command(command_id=f"c_{idx}", **sample)
        tc = command_to_tool_call(cmd, idx)
        parsed = tool_call_to_command(tc, tick=1, seq=idx)
        assert parsed is not None
        assert parsed["op"] == sample["op"]
        revalidated = Command.model_validate(parsed)
        assert revalidated.op == sample["op"]


def test_llm_commander_validates_box_same_type_and_group_and_reserves_actors():
    commander = LlmCommander()
    entities = [
        unit(10, "villager", [0.0, 0.0]),
        unit(30, "militia", [1.0, 1.0]),
        unit(31, "militia", [2.0, 2.0]),
        unit(32, "archer", [1.5, 2.5]),
        unit(33, "archer", [60.0, 60.0]),  # beyond 36-tile double-click radius from cluster
        enemy_tc([40.0, 40.0]),
    ]
    req = request(tick=2, entities=entities, army={"ready_unit_ids": [30, 31, 32, 33], "rally_point": [8.0, 8.0]})
    resp = ChatCompletionResponse(
        id="resp_1",
        model="test",
        choices=[
            ChatCompletionChoice(
                message=ChatMessage(
                    role="assistant",
                    tool_calls=[
                        # box around [0..5, 0..5] selects militia 30,31 & archer 32 (excludes villager 10 and far archer 33)
                        {"id": "tc1", "type": "function", "function": {"name": "move_box", "arguments": '{"box":[-1,-1,5,5],"pos":[15,15],"formation":"box"}'}},
                        # archer 32 was already claimed by move_box; only far archer 33 matches!
                        {"id": "tc2", "type": "function", "function": {"name": "attack_same_type", "arguments": '{"unit_def_id":"archer","target_id":200}'}},
                        # empty box must be rejected
                        {"id": "tc3", "type": "function", "function": {"name": "move_box", "arguments": '{"box":[90,90,95,95],"pos":[15,15],"formation":"line"}'}},
                        # villager is already free; explicit group with already-claimed 30 must drop 30 or reject
                        {"id": "tc4", "type": "function", "function": {"name": "attack_group", "arguments": '{"unit_ids":[30,31],"target_id":200}'}},
                    ],
                )
            )
        ],
    )
    out = commander.finish_response(req, resp)
    cmds = [tc["function"]["name"] for tc in (out.choices[0].message.tool_calls or [])]
    assert cmds == ["move_box", "attack_same_type"]
    reasons = [d.message for d in out.debug if d.category == "LLM_FILTER"]
    assert any("no_matching_units" in r for r in reasons)
    assert any("actor_not_owned" in r for r in reasons)


def test_llm_commander_continue_plan_coalesces_batches_when_capable():
    commander = LlmCommander()
    commander.strategy = commander.strategy.__class__(stance="attack", army_target=4, military_building="barracks", explicit=True)
    commander.phase = "attack"
    commander.attack_committed = True
    units = army(5, pos=[2.0, 2.0])
    entities = units + [enemy_tc([40.0, 40.0])]
    req = request(
        tick=3,
        entities=entities,
        army={"ready_unit_ids": [u["id"] for u in units], "rally_point": [8.0, 8.0]},
    )
    req.observation.capabilities = {"batch_unit_commands": True, "unit_auto_aggro": True}
    out = commander.finish_response(req, ChatCompletionResponse(id="resp_2", model="test", choices=[ChatCompletionChoice(message=ChatMessage(role="assistant"))]))
    calls = out.choices[0].message.tool_calls or []
    attack_groups = [tc for tc in calls if tc["function"]["name"] == "attack_group"]
    assert len(attack_groups) == 1


def test_runtime_coalesces_army_commands_and_preserves_auto_aggro_fights():
    rt = MultiAgentRuntime()
    soldiers = army(6, pos=[2.0, 2.0])
    for s in soldiers:
        s["pos"] = [2.0, 2.0]
    # Test 1: during muster with unit_auto_aggro enabled, active fighter & nearby hostile unit are not pulled away to distant rally
    soldiers[0]["order"] = "ATTACK"
    soldiers[0]["target_id"] = 250
    enemy_soldier = unit(250, "militia", [10.0, 2.0], team=1)
    req = frame(
        tick=1,
        time=1.0,
        entities=soldiers + [enemy_soldier, building(1, "town_center", [0.0, 0.0], is_complete=True)],
        army={"rally_point": [30.0, 30.0], "ready_unit_ids": [u["id"] for u in soldiers]},
    )
    req.observation.capabilities = {"batch_unit_commands": True, "unit_auto_aggro": True}
    out = rt.tick(req)
    # Near enemy [10,2] (within 18 tiles), auto-aggro units must NOT be pulled back to rally [30,30]
    assert not issued(out, "move") and not issued(out, "move_group")

    # Test 2: with no nearby enemies, rally coalesces into a single move_group command and updates all actors
    rt2 = MultiAgentRuntime()
    far_soldiers = army(6, pos=[0.0, 0.0])
    req2 = frame(
        tick=1,
        time=1.0,
        entities=far_soldiers + [building(1, "town_center", [0.0, 0.0], is_complete=True)],
        army={"rally_point": [25.0, 25.0], "ready_unit_ids": [u["id"] for u in far_soldiers]},
    )
    req2.observation.capabilities = {"batch_unit_commands": True, "unit_auto_aggro": True}
    out2 = rt2.tick(req2)
    move_groups = issued(out2, "move_group")
    assert len(move_groups) == 1
    assert set(move_groups[0]["unit_ids"]) == {30, 31, 32, 33, 34, 35}
    assert set(rt2.roles["combat"].memory["command_times"].keys()) == {30, 31, 32, 33, 34, 35}

    # Receipt with selected_unit_ids marks kernel task completed cleanly via reconcile() and releases leases
    receipt = accept(out2)
    cmd_id = move_groups[0]["command_id"]
    goal_pos = move_groups[0]["pos"]
    for item in receipt:
        if item["command_id"] == cmd_id:
            item["selected_unit_ids"] = [30, 31, 32, 33, 34, 35]
    for s in far_soldiers:
        s["pos"] = list(goal_pos)
        s["order"] = "NONE"
    req3 = frame(
        tick=2,
        time=5.0,
        events=receipt,
        entities=far_soldiers + [building(1, "town_center", [0.0, 0.0], is_complete=True)],
        army={"rally_point": [25.0, 25.0], "ready_unit_ids": [u["id"] for u in far_soldiers]},
    )
    req3.observation.capabilities = {"batch_unit_commands": True, "unit_auto_aggro": True}
    rt2.tick(req3)
    assert rt2.kernel.tasks[cmd_id]["status"] == "completed"
    # Verify reconcile directly clears leases when units complete a batch move (before _combat claims next move)
    rt2.kernel.leases = {uid: {"role": "combat", "until": 20.0} for uid in (30, 31, 32, 33, 34, 35)}
    rt2.kernel.tasks[cmd_id]["status"] = "accepted"
    f3 = rt2._frame(req3) if hasattr(rt2, "_frame") else None
    from brain.llm_commander import _DecisionFrame
    frame_obj = _DecisionFrame(rt2.validator, req3)
    rt2.kernel.reports = []
    rt2.kernel.reconcile(frame_obj)
    assert rt2.kernel.tasks[cmd_id]["status"] == "completed"
    assert not any(uid in rt2.kernel.leases for uid in (30, 31, 32, 33, 34, 35))
