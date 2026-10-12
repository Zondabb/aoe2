from copy import deepcopy

import pytest

from brain.army_manager import ArmyManager
from brain.combat_manager import CombatManager
from brain.command_builder import CommandContext
from brain.director import AiDirector
from brain.profile_loader import profile_for_id
from brain.stores import Blackboard, PHASE_ATTACK, PHASE_BOOM, PHASE_DEFEND, PHASE_ECO


PROFILE = profile_for_id("teutons")


def unit(entity_id=2, name="swordsman", team=1, pos=(120, 120), order="NONE", target=None):
    return dict(id=entity_id, kind="unit", def_id=name, team=team, pos=list(pos), hp=60, order=order, target_id=target)


def building(entity_id=9, team=0, name="town_center", pos=(-120, -120)):
    return dict(id=entity_id, kind="building", def_id=name, team=team, pos=list(pos), hp=1000, is_complete=True)


def board(soldier=None, enemies=None):
    soldier = soldier or unit()
    return Blackboard(
        own_tc_pos=(120, 120), map_bounds=(-240, -240, 240, 240),
        team_units=[soldier], team_buildings=[building(1, 1, pos=(120, 120))],
        all_entities=[soldier] + (enemies or []),
    )


def combat_and_army(bb, army=None, phase=PHASE_ATTACK, tick=1):
    ctx = CommandContext(tick=tick)
    engaged = CombatManager().tick_army(ctx, bb, PROFILE, 0, phase)
    army = army or ArmyManager()
    if phase == PHASE_DEFEND:
        army.rally_to_base(ctx, bb, PROFILE, engaged)
    else:
        army.rally(ctx, bb, PROFILE, engaged)
    return ctx


def test_sustained_attack_is_not_cancelled_by_rally_on_later_observations():
    tc = building()
    bb = board(enemies=[tc])
    bb.enemy_tc_pos = tuple(tc["pos"])
    army = ArmyManager()
    first = combat_and_army(bb, army)
    assert [(c.op, c.unit_id, c.target_id) for c in first.commands] == [("attack", 2, 9)]
    bb.team_units[0].update(order="ATTACK", target_id=9)
    # The attack has not reached its target yet: old rally logic cancelled it.
    for tick in range(2, 20):
        assert combat_and_army(bb, army, tick=tick).commands == []


def test_defend_intercepts_base_raider_and_never_attacks_distant_town_center():
    bb = board(unit(pos=(-60, -60), order="ATTACK", target=9), [building(), unit(10, team=0, pos=(130, 125))])
    commands = combat_and_army(bb, phase=PHASE_DEFEND).commands
    assert [(c.op, c.target_id) for c in commands] == [("attack", 10)]
    bb.all_entities = [building()]
    commands = combat_and_army(bb, phase=PHASE_DEFEND).commands
    assert [(c.op, c.pos) for c in commands] == [("move", [120, 120])]


def test_defend_preserves_attack_on_local_raider_without_rally_move():
    bb = board(unit(pos=(80, 90), order="ATTACK", target=10), [unit(10, team=0, pos=(130, 125))])
    assert combat_and_army(bb, phase=PHASE_DEFEND).commands == []


@pytest.mark.parametrize("phase", [PHASE_ECO, PHASE_BOOM, PHASE_ATTACK])
def test_base_threat_has_priority_in_every_director_phase(phase):
    director = AiDirector("teutons")
    director.phase = phase
    director._blackboard.threat_near_base = True
    director._update_phase(CommandContext(1))
    assert director.phase == PHASE_DEFEND


def test_after_defense_time_trigger_resumes_attack_with_small_reinforcement_group():
    director = AiDirector("teutons")
    director.phase = PHASE_DEFEND
    director._blackboard.match_time = PROFILE.attack_time_seconds + 1
    director._blackboard.military_count = 2
    director._update_phase(CommandContext(1))
    assert director.phase == PHASE_ATTACK


def test_unknown_enemy_army_searches_public_geometry_leaves_scout_and_recovers_stall():
    bb = board()
    bb.team_units += [unit(3), unit(4, name="scout_cavalry")]
    army = ArmyManager()
    first = combat_and_army(bb, army)
    assert [(c.op, c.unit_id, c.pos) for c in first.commands] == [("move", 2, [0, 0]), ("move", 3, [0, 0])]
    for soldier in bb.team_units[:2]:
        soldier["order"] = "MOVE"
    bb.match_time = 1
    assert combat_and_army(bb, army, tick=2).commands == []
    bb.match_time = 9
    stalled = combat_and_army(bb, army, tick=3)
    assert [c.pos for c in stalled.commands] == [[-120, -120], [-120, -120]]


def test_army_search_does_not_query_unobserved_enemy_positions():
    empty = board()
    hidden = deepcopy(empty)
    hidden.all_entities = [building(pos=(221, -199))]
    # Army's route uses only public geometry, regardless of unused raw entities.
    commands = []
    for bb in [empty, hidden]:
        ctx = CommandContext(1)
        ArmyManager().rally(ctx, bb, PROFILE)
        commands.append([c.model_dump() for c in ctx.commands])
    assert commands[0] == commands[1]


def test_nearby_troops_take_priority_and_live_target_does_not_flip_with_distance():
    bb = board(unit(order="ATTACK", target=9), [building(pos=(121, 120)), unit(10, team=0, pos=(125, 120))])
    assert combat_and_army(bb).commands[0].target_id == 10
    bb.team_units[0]["target_id"] = 10
    bb.all_entities += [unit(11, team=0, pos=(121, 120))]
    assert combat_and_army(bb).commands == []


def test_search_preserves_external_moves_active_attacks_and_dead_units():
    bb = board(unit(order="MOVE"))
    bb.team_units += [unit(3, order="ATTACK", target=999), dict(unit(4), hp=0)]
    assert combat_and_army(bb).commands == []


def test_remaining_enemy_buildings_are_attacked_after_town_center_falls():
    bb = board(enemies=[dict(building(), hp=0), building(10, name="barracks")])
    assert [(c.op, c.target_id) for c in combat_and_army(bb).commands] == [("attack", 10)]
