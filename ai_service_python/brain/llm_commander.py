"""Persistent strategic intent with a bounded, observation-only RTS executor.

The upstream model chooses strategy and may issue primitive commands. This
module keeps missions alive between slow model calls, validates purchases as a
batch, and fills routine work using the same legal options the game observed.
It never reads a map, opposing team's state, or an unobserved entity registry.
"""
from __future__ import annotations

from collections import deque
from dataclasses import asdict, dataclass
import json
import math
from typing import Any

from brain.build_placement import can_plan_settlement, footprint_visible
from brain.game_data import BUILDINGS, UNITS, UNIT_TRAIN_BUILDING
from brain.land_progression import CATALOG
from brain.profile_loader import profile_for_id
from brain.tool_call_mapper import commands_to_tool_calls, parse_arguments, TOOL_NAMES
from protocol.models import (ChatCompletionChoice, ChatCompletionRequest,
                             ChatCompletionResponse, ChatMessage, ChatTool,
                             ChatToolFunction, Command, DebugEntry)

MAX_COMMANDS = 36
MILITARY_BUILDINGS = {"barracks", "archery_range", "stable", "siege_workshop", "castle"}
RESOURCES = ("food", "wood", "gold", "stone")
SCOUT_TYPES = {"scout_cavalry", "light_cavalry", "hussar"}


@dataclass
class Strategy:
    stance: str = "develop"
    army_target: int = 6
    military_building: str = "barracks"
    explicit: bool = False


@dataclass
class ScoutMission:
    goal: list[float]
    last_pos: list[float]
    last_progress: float


@dataclass
class GatherApproach:
    target_id: int
    best_distance: float
    last_progress: float


def strategy_tool() -> ChatTool:
    return ChatTool(function=ChatToolFunction(
        name="set_strategy",
        description=("Keep a persistent army plan across decisions. Develop maintains economy, "
                     "muster holds troops at rally, attack commits a formed army, defend protects base. "
                     "Routine scouting, legal construction and training continue. This is a server-only tool."),
        parameters={"type": "object", "additionalProperties": False,
                    "properties": {"stance": {"type": "string", "enum": ["develop", "muster", "attack", "defend"]},
                                   "army_target": {"type": "integer", "minimum": 2, "maximum": 40},
                                   "military_building": {"type": "string", "enum": sorted(MILITARY_BUILDINGS)}},
                    "required": ["stance", "army_target"]}))


def _vec(value: Any) -> list[float] | None:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    if any(isinstance(v, bool) or not isinstance(v, (float, int)) or not math.isfinite(v) for v in value):
        return None
    return [float(value[0]), float(value[1])]


def _id(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _distance(a: list[float], b: list[float]) -> float:
    return math.dist(a, b)


class LlmCommander:
    """One instance per match/team; callers serialize prepare/forward/finish."""

    def __init__(self, profile_id: str = "") -> None:
        self.profile_id = profile_id or "default"
        self.profile = profile_for_id(profile_id)
        self.strategy = Strategy(army_target=max(2, min(40, self.profile.military_attack_count)))
        self.enemy_memory: dict[int, dict[str, Any]] = {}
        self.scout_missions: dict[int, ScoutMission] = {}
        self.visited_frontiers: deque[tuple[float, float]] = deque(maxlen=96)
        self.feedback: deque[dict[str, Any]] = deque(maxlen=16)
        self.issued: dict[str, dict[str, Any]] = {}
        self.cooldowns: dict[str, float] = {}
        self.last_time = 0.0
        self.phase = "develop"
        self.attack_committed = False
        self.finished: dict[tuple[int, float], ChatCompletionResponse] = {}
        self.failed_commands: deque[str] = deque(maxlen=128)
        self.gather_approaches: dict[int, GatherApproach] = {}
        self.stalled_workers: set[int] = set()
        self.resource_cooldowns: dict[int, float] = {}
        self.gather_assignments: dict[int, dict[str, Any]] = {}

    def _observe(self, req: ChatCompletionRequest) -> None:
        if req.observation is None:
            return
        now = float(req.metadata.time_sec)
        self.last_time = now
        entities = {int(e["id"]): e for e in req.observation.entities if _id(e.get("id")) is not None}
        for eid, entity in entities.items():
            if entity.get("kind") in ("unit", "building") and entity.get("team") is not None and entity.get("team") != req.metadata.team and _vec(entity.get("pos")):
                self.enemy_memory[eid] = {"id": eid, "kind": entity["kind"], "def_id": entity.get("def_id", ""),
                                          "pos": _vec(entity["pos"]), "last_seen": now}
        # Mobile sightings expire; buildings also expire, rather than becoming
        # an omniscient target forever after a single scout sighting.
        self.enemy_memory = {eid: e for eid, e in self.enemy_memory.items()
                             if now - e["last_seen"] <= (180 if e["kind"] == "building" else 30)}
        reports = [e.model_dump(exclude_none=True) for e in req.events]
        reports += req.observation.decision_context.get("action_feedback", [])
        for report in reports[-32:]:
            if not isinstance(report, dict):
                continue
            if report.get("type") in ("entity_died", "entity_destroyed"):
                self.enemy_memory.pop(report.get("entity_id"), None)
            rejected = report.get("ok") is False or report.get("success") is False or report.get("accepted") is False or str(report.get("type", "")) in ("command_rejected", "action_rejected")
            reason = str(report.get("reason") or "")
            if not rejected and not (reason and reason not in ("ok", "success")):
                continue
            command_id = str(report.get("command_id", ""))
            if command_id and command_id in self.failed_commands:
                continue
            previous = self.issued.get(command_id, report.get("command", {}))
            feedback = {"command_id": command_id, "op": report.get("op", previous.get("op", "")), "reason": reason or "rejected"}
            if feedback not in self.feedback:
                self.feedback.append(feedback)
            if previous:
                self.cooldowns[self._key(previous)] = now + 8
                mission = self.scout_missions.pop(previous.get("unit_id"), None)
                if mission:
                    self.visited_frontiers.append(tuple(round(n, 1) for n in mission.goal))
            if command_id:
                self.failed_commands.append(command_id)
        self.cooldowns = {key: deadline for key, deadline in self.cooldowns.items() if deadline > now}
        if len(self.issued) > 128:
            self.issued = dict(list(self.issued.items())[-96:])
        self.scout_missions = {eid: mission for eid, mission in self.scout_missions.items() if eid in entities}
        self.stalled_workers.clear()
        for eid, worker in entities.items():
            if worker.get("team") != req.metadata.team or worker.get("def_id") != "villager":
                continue
            if worker.get("order") != "GATHER" or worker.get("gather_state") == "to_drop_off" or float(worker.get("carry_amount", 0)) > .001:
                self.gather_approaches.pop(eid, None)
                continue
            target = entities.get(worker.get("target_id"), {})
            if target and _vec(target.get("pos")) and float(target.get("amount", 0)) > 0:
                self.gather_assignments[eid] = {"id": target["id"], "pos": list(target["pos"])}
            elif worker.get("target_id") is None and eid in self.gather_assignments:
                # A once-seen resource can leave current sight while this
                # owned worker is approaching. Retain only that mission's
                # previously observed coordinate, not a hidden entity lookup.
                target = {**self.gather_assignments[eid], "amount": 1}
            if not target or float(target.get("amount", 0)) <= 0:
                self.stalled_workers.add(eid)
                self.gather_approaches.pop(eid, None)
                continue
            if worker.get("gather_state") != "to_resource" or not _vec(worker.get("pos")) or not _vec(target.get("pos")):
                self.gather_approaches.pop(eid, None)
                continue
            distance = _distance(worker["pos"], target["pos"])
            approach = self.gather_approaches.get(eid)
            if approach is None or approach.target_id != target["id"]:
                self.gather_approaches[eid] = GatherApproach(target["id"], distance, now)
            elif distance < approach.best_distance - .75:
                approach.best_distance, approach.last_progress = distance, now
            elif now - approach.last_progress >= 15:
                # Path jitter can defeat the engine's per-frame stuck counter.
                # Measure improvement toward the resource across model turns.
                self.stalled_workers.add(eid)
                self.resource_cooldowns[target["id"]] = now + 120
        self.gather_approaches = {eid: value for eid, value in self.gather_approaches.items() if eid in entities}
        self.resource_cooldowns = {eid: deadline for eid, deadline in self.resource_cooldowns.items() if deadline > now}
        self.gather_assignments = {eid: value for eid, value in self.gather_assignments.items() if eid in entities}

    def prepare_request(self, req: ChatCompletionRequest) -> ChatCompletionRequest:
        if not self.finished or req.metadata.tick >= max(key[0] for key in self.finished):
            self._observe(req)
        if req.observation is None:
            return req.model_copy(deep=True)
        out = req.model_copy(deep=True)
        out.tools = [tool for tool in out.tools if tool.function.name != "set_strategy"] + [strategy_tool()]
        obs = req.observation
        context = obs.decision_context
        own = [e for e in obs.entities if e.get("team") == req.metadata.team]
        enemy = [e for e in obs.entities if e.get("kind") in ("unit", "building") and e.get("team") != req.metadata.team]
        compact_keys = ("id", "kind", "def_id", "pos", "hp", "order", "target_id", "move_goal", "is_complete",
                        "train_queue", "trainable", "train_blocked_reasons", "technologies", "is_researching", "age_upgrade_reason")
        compact = lambda e: {k: e[k] for k in compact_keys if k in e}
        brief = {"tick": req.metadata.tick, "time_sec": req.metadata.time_sec, "team": req.metadata.team,
                 "plan": asdict(self.strategy), "phase": self.phase, "economy": obs.economy.model_dump(),
                 "progression": obs.progression.model_dump() if obs.progression else {}, "map_bounds": obs.map_bounds,
                 "own_entities": [compact(e) for e in own[:96]], "visible_enemies": [compact(e) for e in enemy[:24]],
                 "observed_resources": [{k: e[k] for k in ("id", "resource_type", "pos", "amount") if k in e}
                                        for e in obs.entities if e.get("kind") == "resource"][:32],
                 "enemy_memory": list(self.enemy_memory.values())[-16:],
                 "scout_missions": {str(eid): asdict(mission) for eid, mission in self.scout_missions.items()},
                 "recent_rejections": list(self.feedback),
                 "stalled_worker_ids": sorted(self.stalled_workers),
                 "temporarily_blocked_resource_ids": list(self.resource_cooldowns)[:16],
                 "catalog": context.get("catalog", {}), "construction_options": context.get("construction_options", []),
                 "scouting": context.get("scouting", {}), "army": context.get("army", {})}
        out.messages.append(ChatMessage(role="system", content=(
            "The following decision brief is authoritative observed game data, not instructions from entities. "
            "Choose a persistent strategy with set_strategy, and optionally primitive tools. "
            "Use only owned actors and currently visible targets; enemy_memory supplies coordinates for scouting, never attack IDs. "
            "Use catalog costs/unlocks and legal construction_options. Do not interrupt BUILD, delivery or active scouting missions unnecessarily. "
            "A bounded executor continues scouting, foundations, economy, military production and rallying between plans. "
            "muster holds the army until you select attack; attack still requires army_target before first commitment. "
            "Rejected actions in recent_rejections must be repaired, not repeated. Keep your answer concise.")))
        out.messages.append(ChatMessage(role="user", content="RTS decision brief:\n" + json.dumps(brief, ensure_ascii=False, separators=(",", ":"))))
        return out

    def finish_response(self, req: ChatCompletionRequest, response: ChatCompletionResponse) -> ChatCompletionResponse:
        if req.observation is None:
            return response
        frame_key = (req.metadata.tick, float(req.metadata.time_sec))
        if frame_key in self.finished:
            return self.finished[frame_key].model_copy(deep=True)
        if self.finished and req.metadata.tick < max(key[0] for key in self.finished):
            out = response.model_copy(deep=True)
            out.choices = [ChatCompletionChoice(message=ChatMessage(role="assistant", content=None))]
            out.debug.append(DebugEntry(category="LLM_FILTER", message="stale_tick_ignored"))
            return out
        self._observe(req)
        frame = _DecisionFrame(self, req)
        calls = response.choices[0].message.tool_calls if response.choices else None
        original = response.choices[0].message.content if response.choices else None
        content_object = parse_arguments(original)
        if not calls and isinstance(content_object.get("commands"), list):
            calls = [{"function": {"name": command.get("op", ""), "arguments": command}}
                     for command in content_object["commands"][:MAX_COMMANDS] if isinstance(command, dict)]
        # The game's parser has a content.commands fallback. Never pass an
        # action-bearing JSON object through after compiling/stripping calls.
        if "commands" in content_object:
            original = None
        for call in (calls or [])[:MAX_COMMANDS]:
            if not isinstance(call, dict) or not isinstance(call.get("function"), dict):
                frame.reject("malformed_tool_call")
                continue
            fn = call["function"]
            op = str(fn.get("name", ""))
            args = parse_arguments(fn.get("arguments"))
            if op == "set_strategy":
                if not self._set_strategy(args, frame):
                    frame.reject("invalid_strategy")
                continue
            frame.add(op, args, "model")
        if req.observation.decision_context:
            self._continue_plan(frame)
        out = response.model_copy(deep=True)
        tool_calls = commands_to_tool_calls(frame.commands)
        out.choices = [ChatCompletionChoice(index=0, finish_reason="tool_calls" if tool_calls else "stop",
                                           message=ChatMessage(role="assistant", content=None, tool_calls=tool_calls or None))]
        out.debug.extend(frame.debug)
        out.debug.append(DebugEntry(category="LLM_PLAN", message=json.dumps(
            {"stance": self.strategy.stance, "phase": self.phase, "army_target": self.strategy.army_target,
             "commands": len(frame.commands), "scout_missions": len(self.scout_missions)}, separators=(",", ":"))))
        self.finished[frame_key] = out.model_copy(deep=True)
        if len(self.finished) > 4:
            self.finished.pop(next(iter(self.finished)))
        return out

    def cached_response(self, req: ChatCompletionRequest) -> ChatCompletionResponse | None:
        """The service uses this before paying for an identical upstream call."""
        if req.observation is None:
            return None
        cached = self.finished.get((req.metadata.tick, float(req.metadata.time_sec)))
        return cached.model_copy(deep=True) if cached is not None else None

    def continue_on_failure(self, req: ChatCompletionRequest, reason: str) -> ChatCompletionResponse:
        """Continue established intent without implying a successful LLM call."""
        response = ChatCompletionResponse(
            id=f"chatcmpl_llm_fallback_{req.metadata.tick}", model=req.model,
            choices=[ChatCompletionChoice(message=ChatMessage(role="assistant", content=None))],
            debug=[DebugEntry(category="LLM_FALLBACK", message=f"Upstream failed; continuing observed plan: {reason}")])
        return self.finish_response(req, response)

    def _set_strategy(self, args: dict, frame: _DecisionFrame) -> bool:
        stance = args.get("stance")
        count = args.get("army_target")
        producer = args.get("military_building", self.strategy.military_building)
        if stance not in ("develop", "muster", "attack", "defend") or _id(count) is None or not 2 <= count <= 40:
            return False
        if not isinstance(producer, str) or producer not in MILITARY_BUILDINGS or producer not in frame.building_defs:
            return False
        if self.strategy.stance != stance and stance != "attack":
            self.attack_committed = False
        self.strategy = Strategy(stance, count, producer, True)
        return True

    @staticmethod
    def _key(command: dict) -> str:
        fields = ("op", "unit_id", "builder_id", "building_id", "target_id", "building_def_id", "unit_def_id", "technology_id", "pos")
        values = {key: command[key] for key in fields if key in command}
        if _vec(values.get("pos")):
            values["pos"] = [round(float(n), 3) for n in values["pos"]]
        return json.dumps(values, sort_keys=True, separators=(",", ":"))

    def _continue_plan(self, f: _DecisionFrame) -> None:
        # Finish existing work before consuming resources or pulling another
        # villager away from the economy.
        workers = [e for e in f.units if e.get("def_id") == "villager"]
        for foundation in (b for b in f.buildings if not b.get("is_complete")):
            if any(w.get("order") == "BUILD" and w.get("target_id") == foundation["id"] for w in workers):
                continue
            builder = f.worker()
            if builder:
                f.add("build", {"unit_id": builder["id"], "building_id": foundation["id"]}, "finish_foundation")
            break
        army_context = f.context.get("army", {})
        threat_ids = army_context.get("enemy_near_base_ids", [])
        threats = [f.entities[eid] for eid in threat_ids if eid in f.entities and f.enemy(f.entities[eid])]
        military = [e for e in f.units if e.get("def_id") != "villager"
                    and float(CATALOG["units"].get(e.get("def_id"), f.unit_defs.get(e.get("def_id"), {})).get("attack", 0)) > 0]
        army = [u for u in military if u["id"] not in f.scout_ids]
        ready_ids = army_context.get("ready_unit_ids")
        ready = [u for u in army if (u["id"] in ready_ids if isinstance(ready_ids, list)
                                     else float(u.get("hp", 0)) >= float(u.get("max_hp", 1)) * .45)]
        # A global count alone can launch stragglers one by one. Require a
        # compact majority around one ready soldier before first commitment.
        cluster_size = max((sum(_distance(anchor["pos"], u["pos"]) <= 16 for u in ready) for anchor in ready), default=0)
        formed = len(ready) >= self.strategy.army_target and cluster_size >= math.ceil(self.strategy.army_target * .75)
        self.phase = "defend" if threats or f.obs.derived.threat_near_base else self.strategy.stance
        if self.phase == "develop" and not self.strategy.explicit and (formed or self.attack_committed):
            self.phase = "attack"
        if self.phase == "attack" and formed:
            self.attack_committed = True
        if self.phase == "attack" and not self.attack_committed:
            self.phase = "muster"
        if self.phase == "attack" and self.attack_committed:
            # A temporary infantry scout rejoins the formed army. Dedicated
            # observed scouts retain their mission.
            for soldier in army:
                if soldier.get("def_id") not in SCOUT_TYPES:
                    self.scout_missions.pop(soldier["id"], None)

        producers = [b for b in f.buildings if b.get("is_complete") and b.get("def_id") in MILITARY_BUILDINGS]
        # With one population slot still open, spend the opening military wood
        # before another house. Otherwise 200 wood becomes 170 forever as farms
        # and houses repeatedly consume the first barracks' 175 wood.
        if f.pop_cap - f.pop_used > 0 and not any(b.get("def_id") == "barracks" for b in f.buildings):
            f.place("barracks")
        if f.pop_cap - f.pop_used <= max(2, len(producers)):
            f.place("house")
        if not any(b.get("def_id") == "barracks" for b in f.buildings):
            f.place("barracks")
        elif not any(b.get("def_id") == self.strategy.military_building for b in f.buildings):
            f.place(self.strategy.military_building)

        natural_food = sum(max(0, float(e.get("amount", 0))) for e in f.obs.entities
                           if e.get("kind") == "resource" and e.get("resource_type") == "FOOD")
        if natural_food < 100:
            mills = [b for b in f.buildings if b.get("def_id") == "mill"]
            if not mills:
                f.place("mill")
            elif any(b.get("is_complete") for b in mills):
                farms = [b for b in f.buildings if b.get("def_id") == "farm" and (not b.get("is_complete") or float(b.get("amount", 0)) > 0)]
                first_producer_ready = any(b.get("def_id") == "barracks" and b.get("is_complete") for b in f.buildings)
                farm_target = max(1, min(8, math.ceil(len(workers) * .4))) if first_producer_ready else 1
                if len(farms) < farm_target:
                    f.place("farm")

        # Economy remains alive while the model is deciding how to fight.
        desired_workers = self.profile.villagers_for_age(f.age)
        for producer in f.buildings:
            if producer.get("def_id") != "town_center" or len(workers) >= desired_workers:
                continue
            f.add("train", {"building_id": producer["id"], "unit_def_id": "villager"}, "economy_train")
        for producer in producers:
            candidates = [name for name in producer.get("trainable", []) if name != "villager" and name in f.unit_defs
                          and name != "petard" and float(CATALOG["units"].get(name, f.unit_defs[name]).get("attack", 0)) > 0]
            # Prefer a diversified legal force rather than researching an
            # unaffordable unit or guessing an unobserved unlocked tier.
            counts = {name: sum(u.get("def_id") == name for u in military) for name in candidates}
            candidates.sort(key=lambda name: (counts[name], -float(f.unit_defs[name].get("attack", 0)), name))
            for name in candidates:
                if f.add("train", {"building_id": producer["id"], "unit_def_id": name}, "military_train", quiet=True):
                    break

        # Upgrades use the observed availability, and only surplus after
        # producers have had a chance to replenish their army.
        if self.phase != "defend" and len(army) >= self.strategy.army_target and f.age < 3:
            for tc in (b for b in f.buildings if b.get("def_id") == "town_center" and b.get("age_upgrade_reason") == ""):
                f.add("research_age", {"building_id": tc["id"]}, "age_upgrade", quiet=True)

        # Reserve one scout, preferring the explicit observed IDs and mounted
        # scouts, then an idle soldier. Never send an economic worker while a
        # military scout exists; emergency villager scouting needs no resources.
        self._scout(f)
        resources = [e for e in f.obs.entities if (e.get("kind") == "resource" or (e.get("kind") == "building" and e.get("def_id") == "farm" and e.get("team") == f.team and e.get("is_complete"))) and float(e.get("amount", 0)) > 0 and _vec(e.get("pos")) and e.get("id") not in self.resource_cooldowns]
        def resource_kind(entity: dict) -> str:
            return str(entity.get("resource_type", "")).lower()
        def worker_kind(worker: dict) -> str:
            if worker.get("gather_resource_type"):
                return str(worker["gather_resource_type"]).lower()
            target = resource_kind(f.entities.get(worker.get("target_id"), {}))
            # During delivery target_id names the drop-off building, while the
            # worker still belongs to its last resource's allocation.
            return target or resource_kind(f.entities.get(worker.get("last_resource_id"), {})) or str(worker.get("carry_type") or "").lower()
        available_kinds = {resource_kind(e) for e in resources}
        assigned = {r: sum(w.get("order") == "GATHER" and worker_kind(w) == r for w in workers) for r in RESOURCES}
        ratios = {"food": .45, "wood": .35, "gold": .2, "stone": .0}
        if not any(b.get("def_id") == "barracks" for b in f.buildings) and f.budget["wood"] < 175:
            ratios = {"food": .35, "wood": .55, "gold": .1, "stone": .0}
        rebalanced = 0
        for worker in workers:
            if worker["id"] in f.actors or worker["id"] in self.scout_missions:
                continue
            current = worker_kind(worker)
            desired = max(available_kinds, key=lambda r: ratios.get(r, 0) * len(workers) - assigned.get(r, 0), default="")
            deficit = ratios.get(desired, 0) * len(workers) - assigned.get(desired, 0)
            harvesting = worker.get("order") == "GATHER" and worker.get("gather_state") != "to_drop_off" and float(worker.get("carry_amount", 0)) <= .001
            stalled = harvesting and worker["id"] in self.stalled_workers
            can_rebalance = harvesting and rebalanced < 2 and desired != current and deficit >= .5 and assigned.get(current, 0) > ratios.get(current, 0) * len(workers)
            if worker.get("order", "NONE") != "NONE" and int(worker.get("stuck_frames", 0)) < 12 and not can_rebalance and not stalled:
                continue
            # A blocked wood approach should try another observed tree rather
            # than abandoning an already-understaffed wood economy for food.
            choices = [e for e in resources if resource_kind(e) == current] if stalled and current else []
            resource = min(choices or resources, key=lambda e: (assigned.get(resource_kind(e), 0) / max(.05, ratios.get(resource_kind(e), .05)), _distance(worker["pos"], e["pos"])), default=None)
            if resource:
                if f.add("gather", {"unit_id": worker["id"], "target_id": resource["id"]}, "economy_recover" if stalled else "economy_rebalance" if can_rebalance else "economy_gather"):
                    assigned[resource_kind(resource)] = assigned.get(resource_kind(resource), 0) + 1
                    if harvesting:
                        assigned[current] = max(0, assigned.get(current, 0) - 1)
                        rebalanced += 1

        targets = threats if self.phase == "defend" else [e for e in f.obs.entities if f.enemy(e)]
        # Prefer military defenders, then exposed workers/producers. Town
        # centers are last: charging a fresh small army into TC fire is costly.
        targets.sort(key=lambda e: (e.get("def_id") == "town_center", e.get("kind") != "unit", e.get("def_id") == "villager", _distance(f.base, e["pos"])))
        rally = _vec(army_context.get("rally_point")) or f.base
        for soldier in army:
            if soldier["id"] in f.actors or soldier["id"] in self.scout_missions:
                continue
            if soldier.get("order") == "ATTACK" and f.enemy(f.entities.get(soldier.get("target_id"), {})):
                continue
            if (self.phase == "defend" and targets) or (self.phase == "attack" and self.attack_committed and targets):
                target = min(targets, key=lambda e: (_distance(soldier["pos"], e["pos"]), e.get("def_id") == "town_center")) if self.phase == "defend" else targets[0]
                f.add("attack", {"unit_id": soldier["id"], "target_id": target["id"]}, self.phase)
            elif self.phase == "attack" and self.attack_committed:
                if self.enemy_memory:
                    remembered = max(self.enemy_memory.values(), key=lambda e: (e["kind"] == "building", e["last_seen"]))
                    f.move_if_needed(soldier, remembered["pos"], "search_last_seen")
                else:
                    # A formed army must not wait forever for a scout to find
                    # the enemy. Advance through observed frontiers toward a
                    # public geometric probe; discovery still happens via fog.
                    frontiers = [item["pos"] for item in f.context.get("scouting", {}).get("frontiers", [])
                                 if isinstance(item, dict) and _vec(item.get("pos"))]
                    anchor = self._search_anchor(f, soldier["pos"])
                    goal = min(frontiers, key=lambda p: _distance(p, anchor), default=anchor)
                    f.move_if_needed(soldier, goal, "army_explore")
            elif soldier.get("order", "NONE") in ("NONE", "MOVE"):
                f.move_if_needed(soldier, rally, "rally")

    def _scout(self, f: _DecisionFrame) -> None:
        frontiers = [item.get("pos") for item in f.context.get("scouting", {}).get("frontiers", []) if isinstance(item, dict) and _vec(item.get("pos"))]
        if (not frontiers and not f.context.get("scouting", {}).get("probes")) or self.phase == "defend":
            return
        candidates = [f.entities[eid] for eid in f.scout_ids if eid in f.entities and f.entities[eid] in f.units]
        candidates += [u for u in f.units if u.get("def_id") in SCOUT_TYPES and u not in candidates]
        if not candidates and self.phase == "attack" and self.attack_committed:
            return
        if not candidates:
            candidates = [u for u in f.units if u.get("def_id") != "villager" and u.get("order", "NONE") in ("NONE", "MOVE")]
        if not candidates and not any(e.get("kind") == "resource" and float(e.get("amount", 0)) > 0 for e in f.obs.entities):
            candidates = [u for u in f.units if u.get("def_id") == "villager" and u.get("order", "NONE") == "NONE"][:1]
        for actor in candidates[:1]:
            eid = actor["id"]
            if eid in f.actors or actor.get("order", "NONE") not in ("NONE", "MOVE"):
                continue
            mission = self.scout_missions.get(eid)
            pos = _vec(actor["pos"])
            if mission:
                if _distance(pos, mission.last_pos) >= 1:
                    mission.last_pos, mission.last_progress = pos, f.now
                arrived = _distance(pos, mission.goal) <= 2
                stalled = f.now - mission.last_progress >= 10
                if not arrived and not stalled and actor.get("order") == "MOVE":
                    continue
                self.visited_frontiers.append(tuple(round(n, 1) for n in mission.goal))
            occupied = [m.goal for sid, m in self.scout_missions.items() if sid != eid]
            goals = [p for p in frontiers if all(_distance(p, other) >= 6 for other in occupied)
                     and tuple(round(n, 1) for n in p) not in self.visited_frontiers
                     and _distance(pos, p) > 2]
            known_types = {str(e.get("resource_type", "")).upper() for e in f.obs.entities
                           if (e.get("kind") == "resource" or e.get("def_id") == "farm") and float(e.get("amount", 0)) > 0}
            if self.strategy.stance in ("muster", "attack") or {"FOOD", "WOOD"}.issubset(known_types):
                probes = [item["pos"] for item in f.context.get("scouting", {}).get("probes", [])
                          if isinstance(item, dict) and _vec(item.get("pos")) and _distance(pos, item["pos"]) > 2
                          and tuple(round(n, 1) for n in item["pos"]) not in self.visited_frontiers]
                if probes:
                    goals = probes
            if not goals:
                continue
            anchor = self._search_anchor(f, pos)
            goal = min(goals, key=lambda p: _distance(p, anchor) + .1 * _distance(pos, p))
            if f.add("move", {"unit_id": eid, "pos": goal}, "scout"):
                self.scout_missions[eid] = ScoutMission(list(goal), pos, f.now)

    @staticmethod
    def _search_anchor(f: _DecisionFrame, position: list[float]) -> list[float]:
        box = f.obs.map_bounds
        if not box:
            return f.base
        center = [(float(box["min"][i]) + float(box["max"][i])) * .5 for i in (0, 1)]
        # These are hypotheses from public geometry, never enemy locations.
        if _distance(position, center) > 24 and _distance(position, f.base) < _distance(position, [2 * center[i] - f.base[i] for i in (0, 1)]):
            return center
        return [max(float(box["min"][i]) + 2, min(float(box["max"][i]) - 2, 2 * center[i] - f.base[i])) for i in (0, 1)]


class _DecisionFrame:
    def __init__(self, owner: LlmCommander, req: ChatCompletionRequest) -> None:
        self.owner, self.req, self.obs = owner, req, req.observation
        assert self.obs is not None
        self.context = self.obs.decision_context
        self.team, self.now = req.metadata.team, float(req.metadata.time_sec)
        self.entities = {e["id"]: e for e in self.obs.entities if _id(e.get("id")) is not None}
        self.units = [e for e in self.obs.entities if e.get("kind") == "unit" and e.get("team") == self.team and _vec(e.get("pos"))]
        self.buildings = [e for e in self.obs.entities if e.get("kind") == "building" and e.get("team") == self.team and _vec(e.get("pos"))]
        self.base = _vec(self.obs.derived.own_tc_pos) or [0, 0]
        self.age = self.obs.progression.age if self.obs.progression else 0
        self.commands: list[Command] = []
        self.debug: list[DebugEntry] = []
        self.actors: set[int] = set()
        self.producers: set[int] = set()
        self.placed: set[str] = set()
        self.budget = {r: getattr(self.obs.economy, r) for r in RESOURCES}
        self.pop_used = self.obs.economy.pop_used + self.obs.economy.pop_reserved
        self.pop_cap = self.obs.economy.pop_cap
        context_catalog = self.context.get("catalog", {})
        self.progression_enabled = bool(context_catalog.get("progression_enabled", self.obs.progression is not None))
        self.building_defs = self._catalog(context_catalog.get("buildings"), "buildings")
        self.unit_defs = self._catalog(context_catalog.get("units"), "units")
        self.tech_defs = self._catalog(context_catalog.get("technologies"), "technologies")
        self.scout_ids = [_id(eid) for eid in self.context.get("scouting", {}).get("scout_ids", self.context.get("army", {}).get("scout_ids", []))]

    def _catalog(self, records: Any, kind: str) -> dict[str, dict]:
        if isinstance(records, list):
            return {str(e["id"]): e for e in records if isinstance(e, dict) and e.get("id")}
        if isinstance(records, dict):
            return records
        if self.obs.progression:
            return CATALOG[kind]
        old = BUILDINGS if kind == "buildings" else UNITS if kind == "units" else {}
        return {name: {**record, "cost": {r: record.get("cost_" + r, 0) for r in RESOURCES},
                        "train_at": UNIT_TRAIN_BUILDING.get(name, "")} for name, record in old.items()}

    def enemy(self, entity: dict) -> bool:
        return bool(entity and entity.get("kind") in ("unit", "building") and entity.get("team") is not None and entity.get("team") != self.team and _vec(entity.get("pos")) and float(entity.get("hp", 1)) > 0)

    def reject(self, reason: str) -> None:
        if len(self.debug) < 12:
            self.debug.append(DebugEntry(category="LLM_FILTER", message=reason))

    def worker(self) -> dict | None:
        candidates = [u for u in self.units if u.get("def_id") == "villager" and u["id"] not in self.actors
                      and u.get("order", "NONE") in ("NONE", "GATHER") and u.get("gather_state") != "to_drop_off"
                      and float(u.get("carry_amount", 0)) <= .001]
        return min(candidates, key=lambda u: (u.get("order") != "NONE", u["id"]), default=None)

    def place(self, name: str) -> bool:
        if self.placed or any(b.get("def_id") == name and not b.get("is_complete") for b in self.buildings):
            return False
        # One farm is an opening food bridge; replacements wait until the first
        # military producer is funded. Depleted plots must not eat every wood
        # delivery and permanently starve the barracks.
        if name == "farm" and not any(b.get("def_id") == "barracks" for b in self.buildings) and any(b.get("def_id") == "farm" for b in self.buildings):
            farm_cost = float(self.building_defs.get("farm", {}).get("cost", {}).get("wood", 0))
            barracks_cost = float(self.building_defs.get("barracks", {}).get("cost", {}).get("wood", 175))
            if self.budget["wood"] - farm_cost < barracks_cost:
                return False
        builder = self.worker()
        if builder is None:
            return False
        for option in self.context.get("construction_options", []):
            if option.get("building_def_id") != name:
                continue
            candidate = dict(option)
            # Options may use a different worker; trust that legal/reachable
            # pairing, and skip a worker already consumed earlier in this batch.
            if candidate.get("builder_id") in self.actors:
                continue
            paired_worker = self.entities.get(candidate.get("builder_id"), {})
            if paired_worker.get("order", "NONE") not in ("NONE", "GATHER"):
                continue
            if self.add("place_building", candidate, "construct", quiet=True):
                return True
        return False

    def move_if_needed(self, actor: dict, goal: list[float], source: str) -> bool:
        if _distance(actor["pos"], goal) <= 4:
            return False
        current_goal = _vec(actor.get("move_goal"))
        if actor.get("order") == "MOVE" and current_goal and _distance(current_goal, goal) <= 3:
            return False
        return self.add("move", {"unit_id": actor["id"], "pos": goal}, source, quiet=True)

    def _unlock(self, definition: dict) -> bool:
        if definition.get("available") is False or definition.get("unlocked") is False or definition.get("blocked_reason"):
            return False
        if not self.progression_enabled:
            # Sandbox observations already report actual availability. Their
            # later-age catalog metadata does not impose enabled-match gates.
            return True
        if int(definition.get("required_age", 0)) > self.age:
            return False
        civilizations = definition.get("civilizations", [])
        if civilizations and self.owner.profile.civ_id not in civilizations:
            return False
        prereqs = definition.get("required_buildings", definition.get("prerequisites", []))
        if isinstance(prereqs, list) and any(isinstance(name, str) and not any(b.get("def_id") == name and b.get("is_complete") for b in self.buildings) for name in prereqs):
            return False
        researched = self.obs.progression.researched_technologies if self.obs.progression else {}
        techs = definition.get("required_techs", [])
        if definition.get("required_technology"):
            techs = [*techs, definition["required_technology"]]
        return all(researched.get(name, False) for name in techs)

    def add(self, op: str, args: dict, source: str, quiet: bool = False) -> bool:
        def fail(reason: str) -> bool:
            if not quiet:
                self.reject(f"{op}: {reason}")
            return False
        if op not in TOOL_NAMES:
            return fail("unknown_tool")
        if op == "noop":
            return False
        if len(self.commands) >= MAX_COMMANDS:
            return fail("command_limit")
        allowed = {
            "move": {"unit_id", "pos"}, "stop": {"unit_id"}, "attack": {"unit_id", "target_id"},
            "gather": {"unit_id", "target_id"}, "build": {"unit_id", "building_id"},
            "place_building": {"builder_id", "building_def_id", "pos"}, "train": {"building_id", "unit_def_id"},
            "research_age": {"building_id"}, "cancel_research_age": {"building_id"},
            "research_technology": {"building_id", "technology_id"}, "cancel_technology": {"building_id"},
        }[op]
        command = {key: value for key, value in args.items() if key in allowed}
        command["op"] = op
        key = self.owner._key(command)
        if self.owner.cooldowns.get(key, 0) > self.now:
            return fail("recent_rejection_or_pending")
        uid, bid = _id(command.get("unit_id")), _id(command.get("building_id"))
        actor, building = self.entities.get(uid, {}), self.entities.get(bid, {})
        cost: dict = {}
        population = 0
        if op in ("move", "stop", "attack", "gather", "build"):
            if actor.get("kind") != "unit" or actor.get("team") != self.team or float(actor.get("hp", 1)) <= 0:
                return fail("actor_not_owned")
            if uid in self.actors:
                return fail("actor_conflict")
        if op in ("move", "place_building"):
            pos = _vec(command.get("pos"))
            if pos is None:
                return fail("invalid_position")
            box = self.obs.map_bounds
            if box and any(pos[i] < float(box["min"][i]) or pos[i] > float(box["max"][i]) for i in (0, 1)):
                return fail("position_outside_map")
            command["pos"] = pos
        if op == "attack":
            if not self.enemy(self.entities.get(_id(command.get("target_id")), {})):
                return fail("target_not_visible_enemy")
        if op == "gather":
            resource = self.entities.get(_id(command.get("target_id")), {})
            if actor.get("def_id") != "villager" or float(resource.get("amount", 0)) <= 0 or not (resource.get("kind") == "resource" or resource.get("def_id") == "farm" and resource.get("team") == self.team and resource.get("is_complete")):
                return fail("invalid_gather_target")
        if op == "build":
            if actor.get("def_id") != "villager" or building.get("kind") != "building" or building.get("team") != self.team or building.get("is_complete"):
                return fail("invalid_foundation")
        if op == "place_building":
            definition = self.building_defs.get(str(command.get("building_def_id", "")), {})
            builder_id = _id(command.get("builder_id"))
            builder = self.entities.get(builder_id, {})
            if not definition or not self._unlock(definition):
                return fail("building_locked_or_unknown")
            if builder.get("team") != self.team or builder.get("def_id") != "villager" or builder_id in self.actors:
                return fail("builder_not_available")
            if builder.get("order") == "BUILD" or builder.get("gather_state") == "to_drop_off" or float(builder.get("carry_amount", 0)) > .001:
                return fail("builder_busy")
            # Enhanced observations provide authoritative, visible, reachable
            # sites. Requiring a listed pairing also covers terrain collisions.
            options = self.context.get("construction_options")
            if isinstance(options, list) and not any(e.get("building_def_id") == command["building_def_id"] and e.get("builder_id") == builder_id and _vec(e.get("pos")) and _distance(e["pos"], command["pos"]) < .05 for e in options):
                return fail("site_not_in_legal_options")
            footprint = definition.get("footprint", [1, 1])
            if not footprint_visible(tuple(command["pos"]), footprint, self.obs.placement_visibility):
                return fail("site_not_visible")
            if not isinstance(options, list):
                bounds = (*self.obs.map_bounds["min"], *self.obs.map_bounds["max"]) if self.obs.map_bounds else None
                if not can_plan_settlement(command["building_def_id"], tuple(command["pos"]), [e for e in self.obs.entities if e.get("kind") == "building"], self.building_defs, [e for e in self.obs.entities if e.get("kind") == "resource"], bounds):
                    return fail("site_blocked")
            if self.placed:
                return fail("one_foundation_per_decision")
            uid, cost = builder_id, definition.get("cost", {})
        if op in ("train", "research_age", "research_technology", "cancel_research_age", "cancel_technology"):
            if building.get("kind") != "building" or building.get("team") != self.team or not building.get("is_complete") or float(building.get("hp", 1)) <= 0:
                return fail("producer_not_completed_owned")
            if bid in self.producers:
                return fail("producer_conflict")
            if op in ("train", "research_age", "research_technology"):
                if building.get("is_researching") or not building.get("train_queue_empty", not building.get("train_queue")):
                    return fail("producer_busy")
            if op == "train":
                name = str(command.get("unit_def_id", ""))
                definition = self.unit_defs.get(name, {})
                if not definition or not self._unlock(definition):
                    return fail("unit_locked_or_unknown")
                if "trainable" in building and name not in building["trainable"]:
                    return fail("unit_not_trainable")
                if name not in building.get("trainable", [name]) or definition.get("train_at") and definition["train_at"] != building.get("def_id"):
                    return fail("wrong_training_building")
                if building.get("train_blocked_reasons", {}).get(name):
                    return fail("training_blocked")
                cost, population = definition.get("cost", {}), int(definition.get("population", 1))
            elif op == "research_age":
                if self.age >= 3 or building.get("def_id") != "town_center" or building.get("age_upgrade_reason") != "":
                    return fail("age_not_available")
                record = self.context.get("catalog", {}).get("age_upgrade", {})
                cost = record.get("cost", ({"food": 500}, {"food": 800, "gold": 200}, {"food": 1000, "gold": 800})[min(self.age, 2)])
            elif op == "research_technology":
                name = str(command.get("technology_id", ""))
                options = building.get("technologies", [])
                if not any(e.get("id") == name and e.get("reason") == "" for e in options):
                    return fail("technology_not_available")
                if name not in self.tech_defs:
                    return fail("technology_unknown")
                cost = self.tech_defs[name].get("cost", {})
            elif not building.get("is_researching"):
                return fail("nothing_to_cancel")
        if any(r not in RESOURCES or isinstance(amount, bool) or not isinstance(amount, (int, float)) or not math.isfinite(amount) or amount < 0 for r, amount in cost.items()):
            return fail("invalid_observed_cost")
        if any(self.budget[r] < amount for r, amount in cost.items()):
            return fail("batch_budget_exceeded")
        if self.pop_used + population > self.pop_cap:
            return fail("population_exceeded")
        command["command_id"] = f"llm_{self.req.metadata.tick}_{len(self.commands)}"
        try:
            parsed = Command.model_validate(command)
        except (ValueError, TypeError):
            return fail("malformed_arguments")
        self.commands.append(parsed)
        if uid is not None:
            self.actors.add(uid)
        if op in ("train", "research_age", "research_technology", "cancel_research_age", "cancel_technology"):
            self.producers.add(bid)
        if op == "place_building":
            self.placed.add(command["building_def_id"])
        for resource, amount in cost.items():
            self.budget[resource] -= amount
        self.pop_used += population
        self.owner.issued[command["command_id"]] = dict(command)
        if op == "gather":
            target = self.entities[command["target_id"]]
            self.owner.gather_assignments[uid] = {"id": target["id"], "pos": list(target["pos"])}
        if uid is not None and (source == "model" or op != "move"):
            self.owner.scout_missions.pop(uid, None)
            if source == "model" and op == "move" and (uid in self.scout_ids or actor.get("def_id") in SCOUT_TYPES):
                self.owner.scout_missions[uid] = ScoutMission(list(command["pos"]), list(actor["pos"]), self.now)
        # Suppress purchases reissued before a foundation/queue is observed.
        if op in ("place_building", "train", "research_age", "research_technology"):
            self.owner.cooldowns[key] = self.now + 2
        if source != "model" and len(self.debug) < 12:
            self.debug.append(DebugEntry(category="LLM_EXEC", message=f"{source}: {op}"))
        return True
