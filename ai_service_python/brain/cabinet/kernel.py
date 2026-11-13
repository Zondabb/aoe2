"""Command arbitration, unit leases and task reconciliation for one team.

Phase 1 of docs/cabinet_ai_design.md: this used to live inside the seven-role
runtime. That runtime and the cabinet departments now issue orders through the
same arbiter. A role's own reaction to a report, a failure or a lost unit is
not decided here; it arrives through KernelListener.
"""
from __future__ import annotations

from collections import deque
import copy
import math
from typing import Protocol

from brain.llm_commander import LlmCommander, _DecisionFrame, _distance, _vec, RESOURCES, MAX_COMMANDS
from protocol.models import ChatCompletionRequest

WALL_TYPES = {"palisade_wall", "stone_wall", "fortified_wall"}
FORTIFICATION_TYPES = WALL_TYPES | {"gate", "palisade_gate", "stone_gate"}
TERMINAL = ("completed", "failed", "cancelled")

# Lease policy. Builders may borrow a worker the economy holds and keep it
# longer than other roles keep a unit; nobody takes a unit the player ordered.
BUILDER_ROLES = ("construction", "defense")
LENDING_ROLE = "economy"
WALL_CREW_ROLE = "defense"
HUMAN = "human"
# Roles whose route orders can flood a tick leave this many command slots to
# the executors that run after them.
ROUTE_HEAVY_ROLES = ("scout", "combat")
RESERVED_SLOTS = 12
# The game lets a villager walk at a foundation it cannot reach for ever, and
# nothing else takes a builder off its job. One that makes no headway for
# BUILDER_PATIENCE seconds loses the job; its foundations are then left alone
# for FOUNDATION_REST seconds, doubling each time up to FOUNDATION_REST_LIMIT.
BUILDER_PATIENCE = 60.0
FOUNDATION_REST, FOUNDATION_REST_LIMIT = 120.0, 600.0


class KernelListener(Protocol):
    """Role-side reactions to what the arbiter observes."""

    def kernel_note(self, message: str) -> None: ...
    def report_seen(self, report: dict) -> None: ...
    def unit_released(self, uid: int) -> None: ...
    def unit_stalled(self, uid: int) -> None: ...
    def task_failed(self, task: dict, reason: str) -> None: ...
    def command_issued(self, role: str, op: str, args: dict) -> None: ...


def _actor(command: dict):
    return command.get("unit_id", command.get("builder_id"))


class Kernel:
    """Who may order a unit, which orders are in flight, and what became of them."""

    def __init__(self, validator: LlmCommander, listener: KernelListener) -> None:
        self.validator = validator
        self.listener = listener
        self.now = 0.0
        self.tasks: dict[str, dict] = {}
        self.pending: dict[str, dict] = {}
        self.leases: dict[int, dict] = {}
        self.failures: dict[str, dict] = {}
        self.reports: list[dict] = []
        self.stalled_builders: set[int] = set()
        self._builders: dict[int, dict] = {}
        self._resting: dict[int, dict] = {}
        self._seen_events: deque = deque(maxlen=512)
        self._last_event_seq = -1

    def begin(self, req: ChatCompletionRequest) -> _DecisionFrame:
        """Open this tick's decision frame with every task brought up to date."""
        self.now = float(req.metadata.time_sec)
        self.intake(req)
        # The compatibility validator also consumes feedback. Feed deduplicated
        # events only, or a retried rejection would extend its cooldown forever.
        observed_req = req.model_copy(deep=True)
        observed_req.events = []
        observed_req.observation.decision_context["action_feedback"] = self.reports
        self.validator._observe(observed_req)
        f = _DecisionFrame(self.validator, req)
        self.reconcile(f)
        return f

    def intake(self, req: ChatCompletionRequest) -> list[dict]:
        """This frame's game reports, each delivered once across retries."""
        reports = [event.model_dump(exclude_none=True) for event in req.events]
        reports += [e for e in req.observation.decision_context.get("action_feedback", []) if isinstance(e, dict)]
        fresh = []
        # Sequence values are global stream IDs, so gaps between events visible
        # to this team are normal. Acknowledged metadata alone diagnoses loss.
        for report in sorted(reports, key=lambda e: e.get("seq", self._last_event_seq + 1)):
            seq = report.get("seq")
            if isinstance(seq, int):
                if seq <= self._last_event_seq:
                    continue
                self._last_event_seq = seq
            else:
                token = (report.get("type"), report.get("command_id"), report.get("entity_id"), report.get("time_sec"), report.get("reason"))
                if token in self._seen_events:
                    continue
                self._seen_events.append(token)
            fresh.append(report)
        self.reports = fresh
        return fresh

    def reconcile(self, f: _DecisionFrame) -> None:
        """Advance every task from this frame's reports and observation, then
        charge the frame for orders the game has not yet confirmed."""
        delivery = getattr(f.req.metadata, "event_delivery", {}) or {}
        if delivery.get("gap") or delivery.get("resync_required"):
            self.listener.kernel_note("event_gap: reconcile tasks from authoritative full snapshot")
        for report in self.reports:
            self.listener.report_seen(report)
            command_id = report.get("command_id") or report.get("lineage", {}).get("command_id")
            task = self.tasks.get(command_id)
            rejected = any(report.get(key) is False for key in ("ok", "success", "accepted")) or report.get("type") in ("command_rejected", "action_rejected", "task_failed", "order_failed")
            if task and rejected:
                self.fail(task, str(report.get("reason", "rejected")))
            elif task and report.get("type") in ("command_result", "command_accepted", "action_accepted"):
                if task["status"] == "dispatched":
                    task["status"] = "accepted"
                # Receipt belongs to the same authoritative snapshot. Do not
                # subtract its already-applied expense a second time.
                self.pending.pop(command_id, None)
                if report.get("created_entity_id") is not None:
                    task["created_entity_id"] = report["created_entity_id"]
                if isinstance(report.get("created_entity_ids"), list):
                    task["created_entity_ids"] = [eid for eid in report["created_entity_ids"] if isinstance(eid, int) and not isinstance(eid, bool)]
                if report.get("queue_id") is not None:
                    task["queue_id"] = report["queue_id"]
            elif task and report.get("type") in ("task_completed", "order_completed"):
                task["status"] = "completed"
                self.pending.pop(command_id, None)
            if report.get("type") in ("manual_command", "human_command", "manual_order", "player_command"):
                ids = report.get("unit_ids", [report.get("unit_id", report.get("entity_id"))])
                if report.get("building_id") is not None:
                    ids = [*(ids if isinstance(ids, list) else []), report["building_id"]]
                for uid in ids if isinstance(ids, list) else []:
                    if uid in f.entities and f.entities[uid].get("team") == f.team:
                        self.leases[uid] = {"role": HUMAN, "until": self.now + 12}
                        self.listener.unit_released(uid)
                        for previous in self.tasks.values():
                            if _actor(previous["command"]) == uid and previous["status"] not in TERMINAL:
                                previous["status"] = "cancelled"
                                self.pending.pop(previous["id"], None)
            if report.get("type") == "unit_order_finished":
                previous = self.tasks.get(report.get("previous_lineage", {}).get("command_id"))
                if previous and previous["command"]["op"] in ("move", "stop"):
                    previous["status"] = "completed"
                    self.pending.pop(previous["id"], None)
            if report.get("type") == "unit_stalled":
                self.listener.unit_stalled(report.get("entity_id"))
            if report.get("type") in ("train_completed", "unit_trained", "unit_produced", "training_completed"):
                queue_id = report.get("queue_id")
                producer_id = report.get("building_id", report.get("producer_id"))
                for previous in self.tasks.values():
                    if previous["command"]["op"] == "train" and previous["command"]["building_id"] == producer_id and (previous["id"] == command_id or previous.get("queue_id") == queue_id and queue_id is not None):
                        previous["status"] = "completed"
                        previous["spawned_entity_id"] = report.get("created_entity_id", report.get("entity_id"))
                        self.pending.pop(previous["id"], None)
        for task in list(self.tasks.values()):
            if task["status"] in TERMINAL:
                continue
            command = task["command"]
            actor = f.entities.get(_actor(command), {})
            building = f.entities.get(command.get("building_id"), {})
            op = command["op"]
            observed = False
            completed = False
            if op == "place_building":
                placed = next((b for b in f.buildings if b.get("def_id") == command["building_def_id"] and _distance(b["pos"], command["pos"]) < 2), None)
                if placed:
                    observed, completed = True, bool(placed.get("is_complete"))
                    task["created_entity_id"] = placed["id"]
            elif op == "place_wall":
                ids = task.get("created_entity_ids", [])
                if not ids:
                    # Recover from a lost receipt using only newly observed
                    # owned wall foundations on this exact offered segment.
                    start, end = command["start"], command["end"]
                    dx, dy = end[0] - start[0], end[1] - start[1]
                    length2 = max(.001, dx * dx + dy * dy)
                    for candidate in f.buildings:
                        if candidate["id"] in task["before_ids"] or candidate.get("def_id") not in FORTIFICATION_TYPES:
                            continue
                        t = ((candidate["pos"][0] - start[0]) * dx + (candidate["pos"][1] - start[1]) * dy) / length2
                        if -.01 <= t <= 1.01 and _distance(candidate["pos"], [start[0] + t * dx, start[1] + t * dy]) <= 1:
                            ids.append(candidate["id"])
                    if ids:
                        task["created_entity_ids"] = ids
                pieces = [f.entities[eid] for eid in ids if eid in f.entities]
                observed = bool(pieces)
                # An absent piece may have been destroyed; do not report the
                # entire wall completed until every surviving piece is built.
                completed = bool(ids) and bool(pieces) and all(b.get("is_complete") for b in pieces)
            elif op == "set_gate_state":
                completed = building.get("gate_state") == command["gate_state"]
            elif op == "build":
                observed = actor.get("order") == "BUILD" and actor.get("target_id") == command["building_id"]
                completed = bool(building.get("is_complete"))
            elif op == "train":
                production = building.get("production", {})
                queue_ids = production.get("queue_ids", building.get("train_queue_ids", []))
                if task.get("queue_id") is not None:
                    observed = task["queue_id"] in queue_ids
                else:
                    observed = bool(building.get("train_queue")) or building.get("train_queue_empty") is False
                    if observed and len(queue_ids) == 1:
                        task["queue_id"] = queue_ids[0]
                # A birth at a different producer must not complete this task.
                # Prefer exact spawn lineage; older fixtures use a nearby new
                # entity only once, after this producer's queue has drained.
                born = [e for e in f.units if e.get("def_id") == command["unit_def_id"] and e["id"] not in task["before_ids"]
                        and building and _distance(e["pos"], building["pos"]) < 12
                        and not any(t.get("spawned_entity_id") == e["id"] for t in self.tasks.values())]
                completed = bool(born) and not observed and task["status"] in ("accepted", "running")
                if completed:
                    task["spawned_entity_id"] = min(born, key=lambda e: _distance(e["pos"], building["pos"]))["id"]
            elif op == "research_age":
                observed = bool(building.get("is_researching"))
                completed = f.age > task["before_age"]
            elif op == "research_technology":
                observed = bool(building.get("is_researching"))
                completed = bool(f.obs.progression and f.obs.progression.researched_technologies.get(command["technology_id"]))
            elif op == "move":
                observed = actor.get("order") == "MOVE" and _vec(actor.get("move_goal")) is not None and _distance(actor["move_goal"], command["pos"]) < 3
                completed = bool(actor and _distance(actor["pos"], command["pos"]) <= 3)
            elif op in ("gather", "attack"):
                observed = actor.get("order") == op.upper() and actor.get("target_id") == command.get("target_id")
                # Gathering is a continuing assignment, not a single delivery.
                completed = op == "attack" and task.get("target_destroyed", False)
            if completed:
                task["status"] = "completed"
                self.pending.pop(task["id"], None)
                uid = _actor(command)
                if uid in self.leases and self.leases[uid]["role"] != HUMAN:
                    self.leases.pop(uid, None)
            elif observed:
                task["status"] = "running"
                self.pending.pop(task["id"], None)
                task["last_observed_at"] = self.now
            elif task["status"] == "dispatched" and self.now - task["issued_at"] >= 8:
                self.fail(task, "not_observed_after_receipt_window")
            elif task["status"] in ("accepted", "running") and self.now - task.get("last_observed_at", task["issued_at"]) >= 180:
                task["status"] = "cancelled"
            if _actor(command) is not None and not actor:
                task["status"] = "cancelled"
                self.pending.pop(task["id"], None)
            if op in ("train", "research_age", "research_technology", "set_gate_state") and not building:
                task["status"] = "cancelled"
                self.pending.pop(task["id"], None)
        for task in self.pending.values():
            for resource, amount in task["cost"].items():
                f.budget[resource] = max(0, f.budget[resource] - amount)
            command = task["command"]
            if command["op"] in ("train", "research_age", "research_technology", "set_gate_state"):
                f.producers.add(command["building_id"])
                f.pop_used += task["population"]
            uid = _actor(command)
            if uid is not None:
                f.actors.add(uid)
        self._watch_builders(f)
        # A wall is one continuing job across many foundations. Its queued
        # builder must not be reassigned between segments by another role.
        for worker in f.units:
            if worker.get("build_queue_ids") and worker["id"] not in self.stalled_builders:
                f.actors.add(worker["id"])
                if self.leases.get(worker["id"], {}).get("role") != HUMAN:
                    self.leases[worker["id"]] = {"role": WALL_CREW_ROLE, "until": self.now + 15}
        for uid, lease in self.leases.items():
            if lease["role"] == HUMAN and lease["until"] > self.now:
                if f.entities.get(uid, {}).get("kind") == "building":
                    f.producers.add(uid)
                else:
                    f.actors.add(uid)

    def _watch_builders(self, f: _DecisionFrame) -> None:
        """Take the job from a builder that makes no headway, and rest its foundations.

        Headway is a new section, a shorter queue, a foundation further built or
        a builder nearer to it. Without this one blocked wall section holds its
        builder, and every section queued behind it, for the rest of the match."""
        watched: dict[int, dict] = {}
        self.stalled_builders = set()
        for worker in f.units:
            queue = worker.get("build_queue_ids") or []
            building = worker.get("order") == "BUILD"
            if worker.get("def_id") != "villager" or not (building or queue):
                continue
            uid = worker["id"]
            lease = self.leases.get(uid, {})
            if lease.get("role") == HUMAN and lease["until"] > self.now:
                continue                                    # the player's own order
            target = f.entities.get(worker.get("target_id"), {}) if building else {}
            if target and "build_progress" not in target:
                continue                                    # nothing to measure headway by
            gap = _distance(worker["pos"], target["pos"]) if _vec(target.get("pos")) else math.inf
            done = float(target.get("build_progress") or 0)
            seen = self._builders.get(uid)
            if (seen is None or seen["target"] != target.get("id") or len(queue) < seen["queue"]
                    or done > seen["done"] + 1e-6 or gap < seen["gap"] - .5):
                seen = {"target": target.get("id"), "queue": len(queue), "done": done, "gap": gap, "since": self.now}
            watched[uid] = seen
            if self.now - seen["since"] < BUILDER_PATIENCE:
                continue
            self.stalled_builders.add(uid)
            if not seen.get("released"):
                seen["released"] = True
                self.leases.pop(uid, None)
                for foundation in [fid for fid in [target.get("id"), *queue] if fid is not None]:
                    count = self._resting.get(foundation, {}).get("count", 0) + 1
                    self._resting[foundation] = {"count": count, "until": self.now + min(FOUNDATION_REST_LIMIT, FOUNDATION_REST * 2 ** (count - 1))}
                self.listener.kernel_note(f"builder {uid} made no headway for {int(BUILDER_PATIENCE)}s: job released")
        self._builders = watched
        self._resting = {fid: rest for fid, rest in self._resting.items() if f.entities.get(fid, {}).get("is_complete") is False}

    def at_rest(self, foundation_id) -> bool:
        """True while a foundation that stalled its builder is being left alone."""
        return self._resting.get(foundation_id, {}).get("until", 0) > self.now

    def fail(self, task: dict, reason: str) -> None:
        task["status"], task["reason"] = "failed", reason
        self.pending.pop(task["id"], None)
        key = self.validator._key(task["command"])
        count = self.failures.get(key, {}).get("count", 0) + 1
        self.failures[key] = {"count": count, "until": self.now + min(120, 5 * 2 ** min(count, 5)), "last_failure": self.now}
        task["attempts"] = count
        uid = _actor(task["command"])
        if uid in self.leases and self.leases[uid]["role"] != HUMAN:
            self.leases.pop(uid, None)
        self.listener.task_failed(task, reason)

    def target_destroyed(self, eid) -> None:
        for task in self.tasks.values():
            if task["command"].get("target_id") == eid:
                task["target_destroyed"] = True

    def claim(self, uid: int, role: str, emergency: bool = False) -> bool:
        lease = self.leases.get(uid)
        if lease and lease["until"] > self.now and lease["role"] != role:
            builder_borrow = role in BUILDER_ROLES and lease["role"] == LENDING_ROLE
            if lease["role"] == HUMAN or not (emergency or builder_borrow):
                return False
            self.listener.unit_released(uid)
        self.leases[uid] = {"role": role, "until": self.now + (15 if role in BUILDER_ROLES else 8)}
        return True

    def emit(self, f: _DecisionFrame, role: str, op: str, args: dict, emergency: bool = False) -> bool:
        """Add one order to the frame, or refuse it and leave no trace."""
        # Large armies may all need new routes at once. Leave room for the
        # later construction, production, defense and economy executors; the
        # global command bound remains unchanged. Training is not a move slot.
        if role in ROUTE_HEAVY_ROLES and op in ("move", "attack", "stop") and len(f.commands) >= MAX_COMMANDS - RESERVED_SLOTS:
            return False
        command = {"op": op, **args}
        key = self.validator._key(command)
        failure = self.failures.get(key, {})
        if failure.get("until", 0) > self.now:
            return False
        uid = _actor(args)
        if uid is not None and uid in f.actors:
            return False
        previous_lease = copy.deepcopy(self.leases.get(uid))
        if uid is not None and not self.claim(uid, role, emergency):
            return False
        # Pending exact orders cannot be purchased twice on adjacent snapshots.
        if any(self.validator._key(task["command"]) == key for task in self.pending.values()):
            return False
        before_budget, before_pop = dict(f.budget), f.pop_used
        if not f.add(op, args, role, quiet=True):
            if uid is not None:
                if previous_lease:
                    self.leases[uid] = previous_lease
                else:
                    self.leases.pop(uid, None)
            return False
        parsed = f.commands[-1]
        old_id = parsed.command_id
        epoch = str(getattr(f.req.metadata, "session_epoch", 0))
        parsed.command_id = f"ma_{epoch}_{f.req.metadata.tick}_{len(f.commands) - 1}"
        command = parsed.model_dump(exclude_none=True)
        self.validator.issued.pop(old_id, None)
        self.validator.issued[parsed.command_id] = command
        task = {"id": parsed.command_id, "role": role, "status": "dispatched", "command": command,
                "issued_at": self.now, "cost": {r: before_budget[r] - f.budget[r] for r in RESOURCES if before_budget[r] > f.budget[r]},
                "population": f.pop_used - before_pop, "before_age": f.age,
                "before_ids": [u["id"] for u in f.units] if op == "train" else [b["id"] for b in f.buildings] if op == "place_wall" else [], "attempts": failure.get("count", 0)}
        # A new actor order supersedes the previous continuing assignment.
        if uid is not None:
            for prior in self.tasks.values():
                if _actor(prior["command"]) == uid and prior["status"] in ("accepted", "running"):
                    prior["status"] = "cancelled"
        self.tasks[task["id"]] = task
        self.pending[task["id"]] = task
        self.listener.command_issued(role, op, args)
        return True

    def end_match(self) -> None:
        for task in self.tasks.values():
            if task["status"] not in TERMINAL:
                task["status"] = "completed" if task.get("target_destroyed") else "cancelled"
        self.pending.clear()
        self.leases.clear()
        self.stalled_builders, self._builders, self._resting = set(), {}, {}

    def prune(self, f: _DecisionFrame) -> None:
        """End of tick: keep lifecycle history bounded, preserving all active entries."""
        terminal = [key for key, task in self.tasks.items() if task["status"] in TERMINAL]
        for key in terminal[:-96]:
            self.tasks.pop(key, None)
        self.failures = {k: v for k, v in self.failures.items() if self.now - v["last_failure"] < 300}
        self.leases = {uid: lease for uid, lease in self.leases.items() if lease["until"] > self.now and uid in f.entities}
