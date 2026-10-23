"""Unit-level tactics: focus fire without overkill, and ranged spacing.

Both helpers only use positions, health and combat values of entities the
team can currently see. They emit nothing themselves; the runtime decides
whether a command slot is available.
"""
from __future__ import annotations

from collections import Counter
import math

from .combat_model import Profile, cost_value, damage, dps, profile

FOCUS_WINDOW_SEC = 6.0


class TargetPlanner:
    """Per-frame allocator: kill dangerous/valuable targets fast, spread overkill.

    Allocation must be stable across frames: a unit already attacking keeps its
    commitment on its current target (seeded before anyone chooses), never
    counts its own damage as someone else's overkill, and switches only when
    another target is clearly better. Re-targeting every frame wastes swings.
    """

    def __init__(self, catalog_units: dict | None = None) -> None:
        self.catalog_units = catalog_units or {}
        self.assigned: Counter = Counter()
        self.own: dict = {}
        self._profiles: dict[int, Profile | None] = {}

    def seed(self, units: list[dict], entities: dict, recent: dict | None = None) -> None:
        """Credit ongoing attacks to their current targets before any choice.

        ``recent`` maps unit id -> its last ordered target, so a unit that just
        stepped back (kiting, order MOVE) keeps its claim and its target.
        """
        recent = recent or {}
        for unit in units:
            target_id = unit.get("target_id") if unit.get("order") == "ATTACK" else recent.get(unit.get("id"))
            target = entities.get(target_id)
            if target is not None and target.get("team") != unit.get("team"):
                self._credit(unit, target)

    def _credit(self, unit: dict, target: dict) -> None:
        me, them = self.profile_of(unit), self.profile_of(target)
        if me is None or them is None:
            return
        previous = self.own.pop(unit.get("id"), None)
        if previous is not None:
            self.assigned[previous[0]] -= previous[1]
        amount = damage(me, them) * FOCUS_WINDOW_SEC / me.cooldown
        self.assigned[target.get("id")] += amount
        self.own[unit.get("id")] = (target.get("id"), amount)

    def profile_of(self, entity: dict) -> Profile | None:
        eid = entity.get("id")
        if eid not in self._profiles:
            self._profiles[eid] = profile(str(entity.get("def_id", "")), entity, self.catalog_units)
        return self._profiles[eid]

    def score(self, unit: dict, target: dict, current_id: int | None = None, raid: bool = False) -> float:
        me, them = self.profile_of(unit), self.profile_of(target)
        if me is None or them is None:
            return -math.inf
        hit = damage(me, them)
        if hit <= 0:
            return -math.inf
        hp = float(target.get("hp", them.hp))
        mine = self.own.get(unit.get("id"))
        committed = self.assigned[target.get("id")] - (mine[1] if mine and mine[0] == target.get("id") else 0.0)
        remaining = max(1.0, hp - committed)
        distance = math.dist(unit["pos"], target["pos"])
        travel = max(0.0, distance - me.range) / max(.3, me.speed or .3)
        kill_time = math.ceil(remaining / hit) * me.cooldown + travel
        # Threat is damage the target deals per second to a typical soldier,
        # so artillery and strong melee are removed before cheap fodder.
        threat = them.attack / them.cooldown if them.attack > 0 else 0.0
        value = cost_value(them.cost) / 100.0
        if them.klass == "villager":
            value *= 2.0 if raid else .8
        if them.klass == "siege":
            threat *= 2.5
        result = (value + 1.5 * threat) / (kill_time + 1.0)
        if target.get("id") == current_id:
            result *= 1.35          # stickiness; a unit mid-attack is never its own overkill
        elif committed >= hp:
            result *= .25
        return result

    def choose(self, unit: dict, candidates: list[dict], raid: bool = False, current: int | None = None) -> dict | None:
        if unit.get("order") == "ATTACK":
            current = unit.get("target_id")
        held = next((t for t in candidates if t.get("id") == current), None)
        if held is not None and not self._siege_interrupt(unit, held, candidates):
            # Attack until dead. Re-scoring a busy unit every frame made it chase
            # targets that look nearly dead only because allies' future damage is
            # counted against them, abandoning live targets (measured in duels).
            self._credit(unit, held)
            return held
        best, best_score = None, -math.inf
        for target in candidates:
            value = self.score(unit, target, current, raid)
            if value > best_score:
                best, best_score = target, value
        if best is not None:
            self.commit(unit, best)
        return best

    def _siege_interrupt(self, unit: dict, held: dict, candidates: list[dict]) -> bool:
        """Enemy siege inside our reach outranks finishing an ordinary target."""
        me, current = self.profile_of(unit), self.profile_of(held)
        if me is None or current is None or current.klass == "siege":
            return False
        return any(getattr(self.profile_of(t), "klass", "") == "siege" and math.dist(unit["pos"], t["pos"]) <= me.range + 2
                   for t in candidates)

    def commit(self, unit: dict, target: dict) -> None:
        self._credit(unit, target)


def kite_goal(unit: dict, unit_profile: Profile | None, enemies: list[tuple[dict, Profile]],
              bounds: dict | None = None) -> list | None:
    """Step a ranged soldier away from slower melee that is about to reach it.

    Godot already repositions a ranged unit whose *own target* is inside its
    minimum range, and siege relies on escorts, so both are excluded here.
    """
    if unit_profile is None or not unit_profile.is_ranged or unit_profile.klass in ("siege", "building"):
        return None
    melee = [(e, p) for e, p in enemies if p is not None and not p.is_ranged and p.attack > 0 and not p.static
             and p.klass not in ("villager", "siege")]
    if not melee:
        return None
    entity, closest = min(melee, key=lambda item: math.dist(unit["pos"], item[0]["pos"]))
    distance = math.dist(unit["pos"], entity["pos"])
    if distance >= 2.5 or unit_profile.speed <= closest.speed * 1.05:
        return None
    away = [unit["pos"][i] - entity["pos"][i] for i in (0, 1)]
    length = math.hypot(*away)
    if length < 1e-3:
        away, length = [1.0, 0.0], 1.0
    goal = [unit["pos"][i] + away[i] / length * 3.0 for i in (0, 1)]
    if bounds and "min" in bounds and "max" in bounds:
        goal = [max(bounds["min"][i], min(bounds["max"][i], goal[i])) for i in (0, 1)]
    return goal
