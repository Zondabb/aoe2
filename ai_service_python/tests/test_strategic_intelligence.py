"""Strategic intelligence layer: battle model, opponent model, doctrine, tactics and memory."""
from __future__ import annotations

from collections import Counter
import json

from brain.multi_agent.combat_model import damage, profile, simulate, trade_efficiency
from brain.multi_agent.doctrine import counter_scores, recommend_doctrine
from brain.multi_agent.memory_bank import StrategyMemory
from brain.multi_agent.runtime import MultiAgentRuntime
from brain.multi_agent.scheduler import MultiAgentService
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, enemy_tc, frame, issued, plan
from test_siege_strategy import attack_map, battle, departing


def knights(count, pos, first=300):
    return [unit(first + i, "knight", pos, team=1, hp=100, max_hp=100) for i in range(count)]


# ---------------------------------------------------------------- battle model
def test_damage_mirrors_runtime_formula_and_minimum():
    assert damage(profile("militia"), profile("archer")) == 4      # melee vs 0 melee armor
    assert damage(profile("archer"), profile("militia")) == 3      # pierce vs 1 pierce armor
    assert damage(profile("villager"), profile("battering_ram")) == 6   # -3 melee armor
    assert damage(profile("archer"), profile("battering_ram")) == .5    # floor of 0.5


def test_class_bonuses_follow_what_the_game_actually_applies():
    # Runtime loads class bonuses only for rams/projectile siege/buildings.
    assert damage(profile("spearman"), profile("knight")) == 1
    assert damage(profile("battering_ram"), profile("town_center")) == 125.5
    # If the observation reports a bonus, the model uses it immediately.
    boosted = profile("spearman", {"combat": {"attack_class_bonuses": {"CAVALRY": 15}}})
    assert damage(boosted, profile("knight")) == 16
    assert trade_efficiency(profile("knight"), profile("spearman")) > 1
    catalog = {"spearman": {"attack_class_bonuses": {"CAVALRY": 15}}}
    assert trade_efficiency(profile("spearman", catalog_units=catalog), profile("knight")) > 1


def test_simulation_accounts_for_numbers_and_static_defenses():
    assert simulate([profile("militia")] * 10, [profile("militia")] * 4).winner == "own"
    even = simulate([profile("militia")] * 5, [profile("militia")] * 5)
    supported = simulate([profile("militia")] * 5, [profile("militia")] * 5, enemy_support=[profile("town_center")])
    assert supported.own_survival < even.own_survival and supported.winner == "enemy"
    assert simulate([profile("militia")] * 3, [profile("knight")] * 10).decisive_loss


def test_minimum_range_weapon_cannot_hit_melee_that_has_closed_in():
    adjacent = simulate([profile("militia")] * 3, [profile("mangonel")], gap=1.0)
    assert adjacent.winner == "own" and adjacent.own_survival == 1.0
    from_range = simulate([profile("militia")] * 3, [profile("mangonel")], gap=27.0)
    assert from_range.own_survival < 1.0                # it fires while they approach


# -------------------------------------------------------------- opponent model
def test_opponent_model_keeps_distinct_units_after_sight_is_lost_and_removes_the_dead():
    runtime = MultiAgentRuntime("chinese")
    runtime.tick(frame(1, entities=[building(1, "town_center"), *knights(4, [60, 60])]))
    assert runtime.intel.estimated_army() == Counter({"knight": 4})
    assert "cavalry_focus" in runtime.intel.styles
    runtime.tick(frame(2, entities=[building(1, "town_center")]))                 # out of sight
    assert runtime.intel.estimated_army()["knight"] == 4
    runtime.tick(frame(3, entities=[building(1, "town_center")],
                       events=[{"seq": 5, "type": "entity_died", "entity_id": 300}]))
    assert runtime.intel.estimated_army()["knight"] == 3
    assert runtime.intel.kills["knight"] == 1 and runtime.intel.kill_value == 135


def test_own_losses_and_early_aggression_are_recorded():
    runtime = MultiAgentRuntime("chinese")
    runtime.tick(frame(1, entities=[building(1, "town_center"), unit(30, "militia")], time=100))
    runtime.tick(frame(2, entities=[building(1, "town_center"), *knights(2, [5, 5])], time=101))
    assert runtime.intel.losses["militia"] == 1 and runtime.intel.loss_value == 80
    assert "early_aggression" in runtime.intel.styles


# ------------------------------------------------------------------- doctrine
def test_counter_scores_rank_resource_efficient_answers():
    ranked = counter_scores(["archer", "skirmisher"], Counter({"archer": 6}))
    assert ranked[0]["unit"] == "skirmisher" and ranked[0]["producer"] == "archery_range"
    assert counter_scores(["militia"], Counter()) == []


def test_counter_recommendations_respect_civilization_and_put_trainable_units_first():
    runtime = MultiAgentRuntime("chinese")
    runtime.tick(battle([building(1, "town_center"), *knights(6, [70, 70])], age=2))
    names = [item["unit"] for item in runtime.counter_ranking]
    assert names and not {"teutonic_knight", "elite_teutonic_knight", "paladin"} & set(names)
    flags = [item["available_now"] for item in runtime.counter_ranking]
    assert flags == sorted(flags, reverse=True)


def test_doctrine_recommendation_prefers_proven_records():
    memory = {"record_vs_style": {"boom": {"rush": {"wins": 3, "losses": 0}}}}
    assert recommend_doctrine(["boom"], 400, 5, 8, memory)["strategy"] == "rush"
    assert recommend_doctrine(["early_aggression"], 300, 1, 4)["strategy"] == "turtle"
    assert recommend_doctrine([], 300, 1, 0)["strategy"] == "adaptive"


def test_doctrine_modifies_worker_target_and_technology():
    runtime = MultiAgentRuntime("chinese")
    _, baseline = runtime._worker_targets(0)
    plan(runtime, "commander", strategy="boom")
    assert runtime._worker_targets(0)[1] == min(60, baseline + 12)
    assert runtime._technology_targets()[0] >= 2
    plan(runtime, "commander", strategy="rush")
    assert runtime._technology_targets()[0] == 1          # no castle age before the first sortie
    runtime.roles["combat"].memory["initial_force"] = [30]
    assert runtime._technology_targets()[0] == runtime.roles["technology"].plan["target_age"]


# -------------------------------------------------------------------- tactics
def test_production_switches_to_counter_unit_once_enemy_army_is_seen():
    def range_frame(enemies, tick):
        archery = building(50, "archery_range", trainable=["archer", "skirmisher"])
        req = battle([building(1, "town_center"), archery, *[unit(10 + i) for i in range(6)], *enemies], age=1, tick=tick, time=tick)
        req.observation.economy.pop_cap = 40
        return req
    quiet = MultiAgentRuntime("chinese").tick(range_frame([], 1))
    assert [c["unit_def_id"] for c in issued(quiet, "train") if c["building_id"] == 50] == ["archer"]
    archers = [unit(300 + i, "archer", [80, 80], team=1, hp=30, max_hp=30) for i in range(5)]
    countered = MultiAgentRuntime("chinese").tick(range_frame(archers, 1))
    assert [c["unit_def_id"] for c in issued(countered, "train") if c["building_id"] == 50] == ["skirmisher"]


def test_fixed_composition_plan_overrides_counter_ranking():
    runtime = MultiAgentRuntime("chinese")
    plan(runtime, "combat", composition="archers")
    archery = building(50, "archery_range", trainable=["archer", "skirmisher"])
    req = battle([building(1, "town_center"), archery, *[unit(10 + i) for i in range(6)],
                  *[unit(300 + i, "archer", [80, 80], team=1) for i in range(5)]], age=1)
    req.observation.economy.pop_cap = 40
    trained = [c["unit_def_id"] for c in issued(runtime.tick(req), "train") if c["building_id"] == 50]
    assert trained and trained[0] in ("archer", "skirmisher")   # both are archer-family units


def test_focus_fire_spreads_once_committed_damage_kills_the_target():
    weak = [unit(210, pos=[36, 35], team=1, hp=10, max_hp=25), unit(211, pos=[36, 36], team=1, hp=10, max_hp=25)]
    out = departing().tick(battle([*[unit(30 + i, "militia", [35, 35]) for i in range(4)], *weak]))
    targets = Counter(attack_map(out).values())
    assert set(targets) == {210, 211} and max(targets.values()) <= 3


def test_focus_fire_allocation_is_stable_across_frames():
    runtime = departing()
    soldiers = [unit(30 + i, "militia", [35, 35 + i * .3]) for i in range(6)]
    enemies = [unit(210 + i, "militia", [37, 35 + i], team=1) for i in range(3)]
    first = runtime.tick(battle(soldiers + enemies + [enemy_tc()]))
    assigned = attack_map(first)
    assert len(assigned) == 6
    for soldier in soldiers:
        soldier.update(order="ATTACK", target_id=assigned[soldier["id"]])
    second = runtime.tick(battle(soldiers + enemies + [enemy_tc()], tick=2, time=2, events=accept(first)))
    assert attack_map(second) == {}            # nobody is re-targeted when nothing changed


def test_busy_soldier_does_not_chase_a_target_allies_already_cover():
    soldiers = [unit(30, "militia", [35, 35], order="ATTACK", target_id=210)]
    soldiers += [unit(31 + i, "militia", [35, 36], order="ATTACK", target_id=211) for i in range(3)]
    enemies = [unit(210, "militia", [36, 35], team=1), unit(211, "militia", [36, 36], team=1)]
    out = departing().tick(battle(soldiers + enemies + [enemy_tc([90, 90])]))
    assert 30 not in attack_map(out)                       # keeps attacking 210 until it dies


def test_enemy_siege_in_reach_interrupts_the_current_target():
    soldiers = [unit(30 + i, "militia", [35, 35], order="ATTACK", target_id=210) for i in range(3)]
    enemies = [unit(210, "militia", [36, 35], team=1), unit(211, "mangonel", [36, 36], team=1, hp=50, max_hp=50)]
    out = departing().tick(battle(soldiers + enemies + [enemy_tc([90, 90])]))
    assert 211 in attack_map(out).values()


def test_unit_returns_to_its_target_after_a_kite_step():
    runtime = departing()
    archers = [unit(30, "archer", [35, 35], combat={"range": 16}), unit(31, "archer", [35, 36], combat={"range": 16})]
    enemies = [unit(210, "militia", [41, 35], team=1), unit(211, "militia", [41, 36], team=1, hp=38)]
    first = runtime.tick(battle(archers + enemies + [enemy_tc([90, 90])]))
    assert attack_map(first)[30] == attack_map(first)[31] == 211
    archers[0].update(order="MOVE")                       # stepped back last frame, no ATTACK order now
    archers[1].update(order="ATTACK", target_id=211)
    enemies[0]["hp"] = 30                                  # 210 now ties with 211 on kill time
    second = runtime.tick(battle(archers + enemies + [enemy_tc([90, 90])], tick=2, time=2, events=accept(first)))
    assert attack_map(second).get(30) == 211               # resumes, does not switch


def test_ranged_soldier_kites_slower_adjacent_melee():
    out = departing().tick(battle([unit(30, "archer", [35, 35]), unit(31, "archer", [35, 36]),
                                   unit(210, "militia", [36, 35], team=1)]))
    moves = {c["unit_id"]: c["pos"] for c in issued(out, "move")}
    assert 30 in moves and moves[30][0] < 35                  # stepped away from the militia
    assert all(c["unit_id"] != 30 for c in issued(out, "attack"))


def test_army_disengages_from_fight_the_model_says_is_lost():
    runtime = departing()
    out = runtime.tick(battle([building(1, "town_center"), *[unit(30 + i, "militia", [60, 60]) for i in range(3)],
                               *knights(10, [63, 60]), building(200, "town_center", [95, 95], team=1, hp=2400, max_hp=2400)]))
    assert runtime.goals["phase"] == "retreat"
    assert runtime.roles["combat"].memory["disengagements"] == 1
    assert {c["unit_id"] for c in issued(out, "move")} >= {30, 31, 32}
    assert any("disengage_losing_fight" in str(d) for d in out["debug"])


def test_outmatched_home_guard_commits_every_nearby_soldier():
    runtime = MultiAgentRuntime("chinese")
    guards = [unit(30 + i, "militia", [4 + i, 0]) for i in range(5)]
    req = battle([building(1, "town_center"), *guards, *knights(4, [10, 10])], army={"rally_point": [8, 8], "enemy_near_base_ids": [300, 301, 302, 303]})
    runtime.tick(req)
    assert set(runtime.roles["combat"].memory["defender_ids"]) == {30, 31, 32, 33, 34}


def test_kill_switch_restores_previous_tactics(monkeypatch):
    monkeypatch.setenv("AOE2_AI_INTELLIGENCE", "off")
    soldiers = army_at(4, [35, 35])
    soldiers[0].update(order="ATTACK", target_id=211)
    out = departing().tick(battle(soldiers + [enemy_tc(), unit(210, pos=[36, 35], team=1), unit(211, pos=[37, 35], team=1)]))
    assert {attack_map(out)[uid] for uid in (31, 32, 33)} == {210}          # nearest, as before
    runtime = departing()
    runtime.tick(battle([building(1, "town_center"), *army_at(3, [60, 60]), *knights(10, [63, 60])]))
    assert runtime.goals["phase"] != "retreat" and not runtime.counter_ranking
    plan(runtime, "commander", strategy="boom")
    assert runtime.doctrine == {} and runtime._technology_targets()[0] == runtime.roles["technology"].plan["target_age"]
    context = runtime.planning_context("commander")
    assert not {"intel", "after_action", "strategic_memory"} & set(context)


def army_at(count, pos):
    return [unit(30 + i, "militia", pos) for i in range(count)]


# ---------------------------------------------------------- planning & memory
def test_planning_context_carries_intel_after_action_and_memory():
    runtime = MultiAgentRuntime("chinese")
    runtime.load_strategic_memory({"games": 2, "record_by_doctrine": {"rush": {"wins": 2, "losses": 0}},
                                   "record_vs_style": {}, "recent_lessons": ["rush beat boom in 900s."]})
    runtime.tick(battle([building(1, "town_center"), *[unit(10 + i) for i in range(4)], *knights(3, [70, 70])]))
    commander = runtime.planning_context("commander")
    assert commander["intel"]["estimated_enemy_army"] == {"knight": 3}
    assert commander["intel"]["recommended_doctrine"]["strategy"] in ("adaptive", "rush", "boom", "fast_castle", "timing_push", "turtle")
    assert commander["strategic_memory"]["recent_lessons"] == ["rush beat boom in 900s."]
    assert "after_action" in commander and commander["doctrine"]["strategy"] == "adaptive"
    assert "intel" not in runtime.planning_context("construction")
    json.dumps([runtime.planning_context(role) for role in runtime.roles], allow_nan=False)


def test_match_summary_persists_once_and_feeds_the_next_match(tmp_path):
    path = tmp_path / "strategy_memory.json"
    service = MultiAgentService(memory=StrategyMemory(path))
    over = {"match_over": True, "winner": 0, "type": "destroy_any_enemy_town_center"}
    for tick in (1, 2):
        service.tick(frame(tick, victory_conditions=over))
    stored = json.loads(path.read_text(encoding="utf-8"))["records"]
    assert len(stored) == 1 and stored[0]["result"] == "victory" and stored[0]["lessons"]
    snapshot = StrategyMemory(path).snapshot("chinese")
    assert snapshot["record_by_doctrine"]["adaptive"]["wins"] == 1
    fresh = MultiAgentService(memory=StrategyMemory(path))
    req = frame(1)
    req.metadata = req.metadata.model_copy(update={"match_id": "next-match"})
    fresh.tick(req)
    runtime = fresh._sessions[("next-match", 0)].runtime
    assert runtime.strategic_memory["games"] == 1
