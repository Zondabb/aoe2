"""The general: field command, the army's units and the buildings that train them."""
from __future__ import annotations

from collections import Counter

from brain.llm_commander import MILITARY_BUILDINGS, SCOUT_TYPES
from brain.multi_agent.runtime import DEMOLITION_UNITS

from ..models import from_order
from .base import Department
from .economy import idle_producer

EMERGENCY_RANK, SIEGE_RANK, FIRST_FORCE_RANK, REINFORCEMENT_RANK = 118, 107, 106, 60


class GeneralDept(Department):
    name = "general"
    role = "combat"
    field_roles = ("combat",)

    def __init__(self, field, treasury) -> None:
        super().__init__(field, treasury)
        self.stockpiles: list = []
        self.lineup: dict[int, str] = {}    # producer id -> the unit it should train next

    def update(self, f, mandates, brief) -> None:
        engine = self.field
        self.stockpiles = [m for m in self.mine(mandates) if m.kind == "stockpile" and m.amount]
        for mandate in self.stockpiles:
            if mandate.subject is None:
                size = max(2, min(24, int(mandate.amount)))
                changed = engine.roles["combat"].plan["army_target"] != size
                self.tune("commander", army_target=size)
                self.tune("combat", army_target=size)
                if changed:
                    # As with a model plan: a sortie already mustering keeps its size.
                    if engine.goals["sortie_started"] is None:
                        engine.goals["sortie_target"] = size
                    engine.next_sortie_target = size
        # Moving and fighting cost nothing; this also says which producers the army lacks.
        engine._combat(f)

    def draft(self, f) -> None:
        engine = self.field
        self.begin()
        self.lineup = {}
        plan = engine._production_plan(f)
        counts, siege_count, siege_target = Counter(plan["counts"]), plan["siege_count"], plan["siege_target"]
        under_attack = bool(engine.roles["commander"].memory.get("threat_ids"))
        soldiers = sum(u.get("def_id") != "villager" and u.get("def_id") not in SCOUT_TYPES for u in f.units)
        wanted: dict[str, dict] = {}
        for building in plan["ordered"]:
            if building.get("def_id") not in MILITARY_BUILDINGS:
                continue
            choices = engine._military_choices(f, building, counts, siege_count, siege_target)
            ordered_first = [m.subject for m in self.stockpiles if m.subject and counts[m.subject] < m.amount]
            choices.sort(key=lambda name: name not in ordered_first)
            pick = next((name for name in choices if name in DEMOLITION_UNITS or self._obtainable(f, name)), None)
            free = idle_producer(building) and building["id"] not in f.producers
            # Gatherers follow what the army is waiting to buy.
            for name in choices:
                for resource, amount in f.unit_defs[name].get("cost", {}).items():
                    engine.demands[resource] += amount
                if name == pick and free:
                    break
            if pick is None or not building.get("is_complete"):
                continue
            self.lineup[building["id"]] = pick
            entry = wanted.setdefault(pick, {"producers": 0, "free": 0})
            entry["producers"] += 1
            if free:
                # The next producer chooses knowing what this one is about to train.
                entry["free"] += 1
                counts[pick] += 1
                siege_count += pick in DEMOLITION_UNITS
        for name, entry in wanted.items():
            definition = f.unit_defs[name]
            mandate = next((m for m in self.stockpiles if m.subject == name), None)
            origin = mandate.origin if mandate else "routine"
            count = entry["producers"]
            if under_attack:
                urgency, rank = 3, EMERGENCY_RANK
            elif name in DEMOLITION_UNITS and plan["siege_needed"]:
                urgency, rank = 2, SIEGE_RANK
            elif plan["first_force_needed"]:
                urgency, rank = 2, FIRST_FORCE_RANK
                count = max(count, engine.goals["sortie_target"] - soldiers)
            else:
                urgency, rank = (2, FIRST_FORCE_RANK) if from_order(origin) else (1, REINFORCEMENT_RANK)
            if mandate is not None:
                count = max(count, mandate.amount - plan["counts"][name])
                urgency += mandate.urgency == "rush"
            self.want(("unit", name), name, definition.get("cost", {}), count=count, capacity=max(1, entry["free"]),
                      pop=int(definition.get("population", 1)) * count, urgency=urgency, rank=rank, origin=origin,
                      emergency=under_attack)
        self.building_wishes(f)
        self.settle()

    def _obtainable(self, f, name: str) -> bool:
        """A unit is worth waiting for only if each resource in its price is in stock or can be gathered:
        there are villagers and a known source of it."""
        engine = self.field
        villagers = any(u.get("def_id") == "villager" for u in f.units)
        sources = {engine._resource_kind(e) for e in engine._known_resources(f)} | {engine._resource_kind(b) for b in f.buildings}
        return all(f.budget[r] >= amount or villagers and r in sources
                   for r, amount in f.unit_defs[name].get("cost", {}).items())

    def train(self, f, building: dict) -> bool:
        name = self.lineup.get(building["id"])
        request = self.book.get(("unit", name)) if name else None
        if request is None:
            return False
        with self.treasury.purse(f, request.id):
            return self.field._emit(f, "combat", "train", {"building_id": building["id"], "unit_def_id": name})
