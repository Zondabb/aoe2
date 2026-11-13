"""The command arbiter on its own: leases, order admission and task follow-up."""
from __future__ import annotations

import itertools

from brain.cabinet.kernel import Kernel
from brain.land_progression import CATALOG
from brain.llm_commander import LlmCommander, MAX_COMMANDS
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, frame

FOOD, WOOD = 100, 101
VILLAGER_FOOD = CATALOG["units"]["villager"]["cost"]["food"]
TRAIN = {"building_id": 1, "unit_def_id": "villager"}


class Listener:
    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def kernel_note(self, message): self.calls.append(("note", message))
    def report_seen(self, report): self.calls.append(("report", report["type"]))
    def unit_released(self, uid): self.calls.append(("released", uid))
    def unit_stalled(self, uid): self.calls.append(("stalled", uid))
    def task_failed(self, task, reason): self.calls.append(("failed", task["id"], reason))
    def command_issued(self, role, op, args): self.calls.append(("issued", role, op))

    def heard(self, kind) -> list:
        return [call[1:] for call in self.calls if call[0] == kind]


class Team:
    """The kernel's share of a tick, with no role logic around it."""

    def __init__(self) -> None:
        self.listener = Listener()
        self.kernel = Kernel(LlmCommander("chinese"), self.listener)
        self.task_ids = itertools.count()

    def frame(self, tick=1, entities=None, events=(), time=None, delivery=None, **context):
        req = frame(tick, entities=entities, events=events, time=time, **context)
        if delivery:
            req.metadata = req.metadata.model_copy(update={"event_delivery": delivery})
        return self.kernel.begin(req)

    def task(self, command, status="accepted", **extra) -> dict:
        """A task as emit() records it, for orders these fixtures cannot legally issue."""
        task = {"id": f"t{next(self.task_ids)}", "role": "defense", "status": status, "command": command,
                "issued_at": self.kernel.now, "cost": {}, "population": 0, "before_age": 0, "before_ids": [],
                "attempts": 0, **extra}
        self.kernel.tasks[task["id"]] = task
        return task


def world(*extra, tc=None, units=None):
    """The default base; a test swaps the town center or the units to show another state."""
    return [tc or building(1, "town_center"),
            *(units if units is not None else [unit(10), unit(11), unit(12), unit(20, "scout_cavalry")]),
            {"id": FOOD, "kind": "resource", "resource_type": "FOOD", "pos": [5, 5], "amount": 1000},
            {"id": WOOD, "kind": "resource", "resource_type": "WOOD", "pos": [5, -5], "amount": 1000}, *extra]


def receipt(task, seq=1, **fields):
    return {"seq": seq, "type": "command_result", "command_id": task["id"], "ok": True, **fields}


def test_unconfirmed_order_is_charged_to_later_frames_until_the_game_answers():
    team = Team()
    f = team.frame(1)
    assert team.kernel.emit(f, "economy", "train", TRAIN)
    task = team.kernel.tasks["ma_test-epoch_1_0"]
    assert task["status"] == "dispatched" and task["role"] == "economy"
    assert task["cost"] == {"food": VILLAGER_FOOD} and task["population"] == 1
    assert f.commands[0].command_id == task["id"] and team.kernel.validator.issued[task["id"]]["op"] == "train"
    assert team.listener.heard("issued") == [("economy", "train")]

    waiting = team.frame(2)
    assert waiting.budget["food"] == 500 - VILLAGER_FOOD and waiting.pop_used == 5 and 1 in waiting.producers
    assert not team.kernel.emit(waiting, "economy", "train", TRAIN)  # the same purchase is still in flight

    answered = team.frame(3, events=[receipt(task, queue_id=7, created_entity_id=40)])
    assert task["status"] == "accepted" and task["queue_id"] == 7 and task["created_entity_id"] == 40
    assert not team.kernel.pending
    assert answered.budget["food"] == 500 and answered.pop_used == 4 and 1 not in answered.producers

    team.frame(4, events=[{"seq": 2, "type": "task_completed", "command_id": task["id"]}])
    assert task["status"] == "completed"


def test_reports_reach_the_listener_once_across_retried_frames():
    team = Team()
    stalled = {"seq": 5, "type": "unit_stalled", "entity_id": 10}
    unsequenced = {"type": "unit_stalled", "entity_id": 11, "time_sec": 3}
    team.frame(1, events=[stalled], action_feedback=[unsequenced])
    team.frame(2, events=[stalled, {"seq": 6, "type": "unit_stalled", "entity_id": 12}], action_feedback=[unsequenced])
    assert team.listener.heard("stalled") == [(11,), (10,), (12,)]
    assert team.listener.heard("report") == [("unit_stalled",)] * 3
    assert [report["entity_id"] for report in team.kernel.reports] == [12]


def test_a_unit_belongs_to_one_role_until_its_lease_ends():
    team = Team()
    kernel = team.kernel
    assert kernel.claim(10, "economy") and kernel.leases[10] == {"role": "economy", "until": 8.0}
    assert not kernel.claim(10, "combat")
    assert kernel.claim(10, "combat", emergency=True) and team.listener.heard("released") == [(10,)]
    # Builders borrow from the economy without an emergency and hold longer.
    assert kernel.claim(11, "economy") and kernel.claim(11, "construction")
    assert kernel.leases[11] == {"role": "construction", "until": 15.0}
    assert not kernel.claim(11, "economy")
    kernel.now = 15.0
    assert kernel.claim(11, "economy")


def test_refused_order_leaves_the_lease_as_it_was():
    team = Team()
    f = team.frame(1)
    team.kernel.claim(10, "economy")
    held = dict(team.kernel.leases[10])
    assert not team.kernel.emit(f, "construction", "gather", {"unit_id": 10, "target_id": 999})
    assert team.kernel.leases[10] == held
    assert not team.kernel.emit(f, "economy", "gather", {"unit_id": 11, "target_id": 999})
    assert 11 not in team.kernel.leases and not team.kernel.tasks and not f.commands


def test_player_order_takes_the_unit_and_ends_its_tasks():
    team = Team()
    f = team.frame(1)
    assert team.kernel.emit(f, "economy", "gather", {"unit_id": 10, "target_id": FOOD})
    assert team.kernel.emit(f, "economy", "train", TRAIN)
    gather = team.kernel.tasks["ma_test-epoch_1_0"]

    taken = team.frame(2, events=[{"seq": 1, "type": "manual_command", "unit_ids": [10]},
                                  {"seq": 2, "type": "player_command", "building_id": 1}])
    assert team.kernel.leases[10] == {"role": "human", "until": 14.0} and team.kernel.leases[1]["role"] == "human"
    assert gather["status"] == "cancelled" and gather["id"] not in team.kernel.pending
    assert team.listener.heard("released") == [(10,), (1,)]
    assert 10 in taken.actors and 1 in taken.producers
    assert not team.kernel.claim(10, "combat", emergency=True)
    assert not team.kernel.emit(taken, "economy", "gather", {"unit_id": 10, "target_id": WOOD})


def test_rejection_backs_off_and_releases_the_unit():
    team = Team()
    f = team.frame(1)
    move = {"unit_id": 20, "pos": [20, 20]}
    assert team.kernel.emit(f, "scout", "move", move)
    task = team.kernel.tasks["ma_test-epoch_1_0"]
    key = team.kernel.validator._key({"op": "move", **move})

    f = team.frame(2, events=[{"seq": 1, "type": "command_result", "command_id": task["id"], "ok": False, "reason": "blocked"}])
    assert task["status"] == "failed" and task["reason"] == "blocked" and task["attempts"] == 1
    assert team.kernel.failures[key] == {"count": 1, "until": 12.0, "last_failure": 2.0}
    assert 20 not in team.kernel.leases and not team.kernel.pending
    assert team.listener.heard("failed") == [(task["id"], "blocked")]
    assert not team.kernel.emit(f, "scout", "move", move)

    again = team.task({"op": "move", **move}, status="dispatched")
    team.kernel.fail(again, "blocked")
    assert team.kernel.failures[key]["count"] == 2 and team.kernel.failures[key]["until"] == 22.0


def test_order_the_game_never_shows_fails_after_the_receipt_window():
    team = Team()
    f = team.frame(1)
    assert team.kernel.emit(f, "scout", "move", {"unit_id": 20, "pos": [20, 20]})
    task = team.kernel.tasks["ma_test-epoch_1_0"]
    team.frame(2, time=8.5)
    assert task["status"] == "dispatched"
    team.frame(3, time=9)
    assert task["status"] == "failed" and task["reason"] == "not_observed_after_receipt_window"


def test_unit_orders_run_while_observed_and_complete_on_arrival_or_report():
    team = Team()
    team.frame(1)
    team.kernel.claim(20, "scout")
    move = team.task({"op": "move", "unit_id": 20, "pos": [20, 20]})
    other = team.task({"op": "move", "unit_id": 12, "pos": [9, 9]})
    gather = team.task({"op": "gather", "unit_id": 10, "target_id": FOOD})
    strike = team.task({"op": "attack", "unit_id": 11, "target_id": 300})

    gathering = unit(10, order="GATHER", target_id=FOOD)
    team.frame(2, entities=world(units=[gathering, unit(11), unit(12), unit(20, "scout_cavalry", order="MOVE", move_goal=[20, 21])]),
               events=[{"seq": 1, "type": "unit_order_finished", "entity_id": 12, "previous_lineage": {"command_id": other["id"]}}])
    assert move["status"] == "running" and move["last_observed_at"] == 2.0
    assert other["status"] == "completed" and gather["status"] == "running" and strike["status"] == "accepted"

    team.kernel.target_destroyed(300)
    team.frame(3, entities=world(units=[gathering, unit(11), unit(12), unit(20, "scout_cavalry", [19, 19])]))
    assert move["status"] == "completed" and 20 not in team.kernel.leases
    assert strike["status"] == "completed"
    # Gathering is a continuing assignment; it lapses only when unseen for long.
    team.frame(4, time=182)
    assert gather["status"] == "running"
    team.frame(5, time=183)
    assert gather["status"] == "cancelled"


def test_production_orders_follow_the_queue_and_the_birth():
    team = Team()
    team.frame(1)
    by_report = team.task(dict(TRAIN, op="train"), queue_id=7)
    by_birth = team.task(dict(TRAIN, op="train"), before_ids=[10, 11, 12, 20])
    busy = building(1, "town_center", train_queue_empty=False, production={"queue_ids": [8]})
    team.frame(2, entities=world(tc=busy),
               events=[{"seq": 1, "type": "train_completed", "building_id": 1, "queue_id": 7, "created_entity_id": 40}])
    assert by_report["status"] == "completed" and by_report["spawned_entity_id"] == 40
    assert by_birth["status"] == "running" and by_birth["queue_id"] == 8

    team.frame(3, entities=world(unit(41, pos=[1, 1])))
    assert by_birth["status"] == "completed" and by_birth["spawned_entity_id"] == 41


def test_construction_orders_follow_the_foundations():
    team = Team()
    team.frame(1)
    house = team.task({"op": "place_building", "builder_id": 12, "building_def_id": "house", "pos": [0, 24]})
    wall = team.task({"op": "place_wall", "builder_id": 11, "building_def_id": "palisade_wall", "start": [10, 0], "end": [14, 0],
                      "include_gate": False}, before_ids=[1])
    help_build = team.task({"op": "build", "unit_id": 10, "building_id": 50})
    pieces = [building(60 + i, "palisade_wall", [10 + i, 0], complete=i < 2) for i in range(3)]
    stray = building(70, "palisade_wall", [12, 5], complete=True)
    team.frame(2, entities=world(building(50, "house", [0, 24.5], complete=False), *pieces, stray,
                                 units=[unit(10, order="BUILD", target_id=50), unit(11), unit(12)]))
    assert house["status"] == "running" and house["created_entity_id"] == 50
    assert wall["status"] == "running" and wall["created_entity_ids"] == [60, 61, 62]
    assert help_build["status"] == "running"

    done = [building(60 + i, "palisade_wall", [10 + i, 0]) for i in range(3)]
    team.frame(3, entities=world(building(50, "house", [0, 24.5]), *done))
    assert [task["status"] for task in (house, wall, help_build)] == ["completed"] * 3


def test_research_and_gate_orders_complete_on_the_observed_result():
    team = Team()
    team.frame(1)
    age = team.task({"op": "research_age", "building_id": 1}, before_age=0)
    tech = team.task({"op": "research_technology", "building_id": 1, "technology_id": "loom"})
    gate = team.task({"op": "set_gate_state", "building_id": 55, "gate_state": "locked"})
    team.frame(2, entities=world(building(55, "palisade_gate", [10, 0], gate_state="auto"),
                                 tc=building(1, "town_center", is_researching=True)))
    assert age["status"] == "running" and tech["status"] == "running" and gate["status"] == "accepted"

    req = frame(3, entities=world(building(55, "palisade_gate", [10, 0], gate_state="locked")))
    req.observation.progression.age = 1
    req.observation.progression.researched_technologies = {"loom": True}
    team.kernel.begin(req)
    assert [task["status"] for task in (age, tech, gate)] == ["completed"] * 3


def test_task_ends_when_its_actor_or_producer_is_gone():
    team = Team()
    team.frame(1)
    walker = team.task({"op": "move", "unit_id": 20, "pos": [20, 20]})
    trainer = team.task(dict(TRAIN, op="train"))
    team.kernel.pending.update({walker["id"]: walker, trainer["id"]: trainer})
    team.frame(2, entities=world(units=[unit(10), unit(11), unit(12)])[1:])
    assert walker["status"] == "cancelled" and trainer["status"] == "cancelled" and not team.kernel.pending


def test_wall_crew_keeps_its_builder_between_segments():
    team = Team()
    f = team.frame(1, entities=world(units=[unit(10, build_queue_ids=[60, 61]), unit(11), unit(12)]))
    assert team.kernel.leases[10] == {"role": "defense", "until": 16.0} and 10 in f.actors
    assert not team.kernel.emit(f, "economy", "gather", {"unit_id": 10, "target_id": FOOD})


def wall_section(eid, pos, progress=0.0):
    return building(eid, "palisade_wall", pos, is_complete=False, build_progress=progress)


def wall_builder(pos=(20, 0), target=60, queue=(61,)):
    return unit(10, pos=list(pos), order="BUILD", target_id=target, build_queue_ids=list(queue))


def test_a_builder_that_makes_no_headway_loses_the_job_and_its_sections_rest():
    team = Team()
    sections = [wall_section(60, [30, 0]), wall_section(61, [31, 0])]

    def tick(number, now, builder):
        return team.frame(number, entities=world(*sections, units=[builder, unit(11), unit(12)]), time=now)

    held = tick(1, 0, wall_builder())
    assert 10 in held.actors and team.kernel.leases[10]["role"] == "defense"
    assert 10 in tick(2, 59, wall_builder()).actors and not team.kernel.at_rest(60)

    freed = tick(3, 60, wall_builder())                      # a minute at the same distance, nothing built
    assert 10 not in freed.actors and 10 not in team.kernel.leases and team.kernel.stalled_builders == {10}
    assert team.kernel.at_rest(60) and team.kernel.at_rest(61)
    assert team.listener.heard("note") == [("builder 10 made no headway for 60s: job released",)]
    assert team.kernel.emit(freed, "economy", "gather", {"unit_id": 10, "target_id": WOOD})

    tick(4, 61, unit(10, order="GATHER", target_id=WOOD))    # back at work: nothing left to watch
    assert not team.kernel.stalled_builders and team.kernel.at_rest(60)
    tick(5, 181, unit(10, order="GATHER", target_id=WOOD))
    assert not team.kernel.at_rest(60)                        # two minutes later the section may be tried again

    # A second builder stalls on the same section: it rests twice as long.
    tick(6, 200, wall_builder(queue=()))
    tick(7, 260, wall_builder(queue=()))
    assert team.kernel.stalled_builders == {10} and team.kernel.at_rest(60)
    tick(8, 499, unit(10))
    assert team.kernel.at_rest(60)
    tick(9, 501, unit(10))
    assert not team.kernel.at_rest(60)
    assert len(team.listener.heard("note")) == 2


def test_a_builder_making_headway_keeps_the_job():
    team = Team()

    def tick(number, now, builder, *sections):
        return team.frame(number, entities=world(*sections, units=[builder, unit(11), unit(12)]), time=now)

    far, near = wall_section(60, [80, 0]), wall_section(61, [81, 0])
    # Walking there, then building, then on to the next section: each is headway.
    tick(1, 0, wall_builder((20, 0)), far, near)
    tick(2, 50, wall_builder((60, 0)), far, near)
    tick(3, 100, wall_builder((79, 0)), far, near)
    tick(4, 150, wall_builder((79, 0)), wall_section(60, [80, 0], progress=.5), near)
    tick(5, 200, wall_builder((79, 0), target=61, queue=()), near)
    last = tick(6, 250, wall_builder((79, 0), target=61, queue=()), wall_section(61, [81, 0], progress=.4))
    assert not team.kernel.stalled_builders and not team.kernel.at_rest(60) and team.listener.heard("note") == []

    # A foundation that reports no progress figure gives nothing to judge by.
    blind = Team()
    for number, now in enumerate((0, 100, 200), 1):
        blind.frame(number, entities=world(building(60, "house", [30, 0], is_complete=False),
                                           units=[unit(10, pos=[20, 0], order="BUILD", target_id=60)]), time=now)
    assert not blind.kernel.stalled_builders

    # A builder working on the player's own order is the player's to manage.
    owned = Team()
    for number, now in enumerate((0, 100, 200), 1):
        owned.kernel.leases[10] = {"role": "human", "until": now + 30}
        owned.frame(number, entities=world(wall_section(60, [30, 0]), units=[wall_builder(queue=())]), time=now)
    assert not owned.kernel.stalled_builders and not owned.kernel.at_rest(60)


def test_route_heavy_roles_leave_command_slots_for_later_executors():
    team = Team()
    soldiers = [unit(30 + i, "militia", [0, 0]) for i in range(MAX_COMMANDS)]
    f = team.frame(1, entities=world(*soldiers))
    sent = [team.kernel.emit(f, "combat", "move", {"unit_id": soldier["id"], "pos": [10 + i, 10]})
            for i, soldier in enumerate(soldiers)]
    assert sum(sent) == MAX_COMMANDS - 12 and len(f.commands) == MAX_COMMANDS - 12
    assert team.kernel.emit(f, "economy", "train", TRAIN)


def test_event_gap_is_noted_for_the_listener():
    team = Team()
    team.frame(1, delivery={"gap": True})
    assert team.listener.heard("note") == [("event_gap: reconcile tasks from authoritative full snapshot",)]


def test_match_end_and_pruning_bound_what_is_kept():
    team = Team()
    f = team.frame(1)
    active = team.task({"op": "gather", "unit_id": 10, "target_id": FOOD})
    for _ in range(100):
        team.task({"op": "move", "unit_id": 20, "pos": [1, 1]}, status="completed")
    team.kernel.leases.update({10: {"role": "economy", "until": 9.0}, 11: {"role": "economy", "until": 1.0},
                               99: {"role": "combat", "until": 9.0}})
    team.kernel.failures.update({"old": {"count": 1, "until": 0, "last_failure": -300.0},
                                 "recent": {"count": 1, "until": 0, "last_failure": -200.0}})
    team.kernel.prune(f)
    assert len(team.kernel.tasks) == 97 and active["id"] in team.kernel.tasks
    assert list(team.kernel.leases) == [10] and list(team.kernel.failures) == ["recent"]

    hit = team.task({"op": "attack", "unit_id": 11, "target_id": 300}, target_destroyed=True)
    team.kernel.pending[active["id"]] = active
    team.kernel.end_match()
    assert active["status"] == "cancelled" and hit["status"] == "completed"
    assert not team.kernel.pending and not team.kernel.leases
