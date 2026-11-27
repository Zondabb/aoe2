"""The general: field command, the army's units and the buildings that train them."""
from __future__ import annotations

from collections import Counter

from brain.llm_commander import MILITARY_BUILDINGS, SCOUT_TYPES
from brain.multi_agent.runtime import DEMOLITION_UNITS

from ..models import ROUTINE, from_order
from ..orders import (ARMY_STOCKPILE_CAP, BUILD, STOCKPILE_CAP, UNITS, later_forms, military_population, needs_of,
                      population_full_for_muster, stockpile_count)
from .base import Department
from .economy import idle_producer

EMERGENCY_RANK, SIEGE_RANK, FIRST_FORCE_RANK, REINFORCEMENT_RANK = 118, 107, 106, 60
ATTACK_NOW_FORCE = 2      # an order to attack leaves with as few as this many ready soldiers
RECALL_SECONDS = 20


class GeneralDept(Department):
    name = "general"
    role = "combat"
    field_roles = ("combat",)

    def __init__(self, field, treasury) -> None:
        super().__init__(field, treasury)
        self.stockpiles: list = []
        self.stance: str | None = None      # "attack" or "hold" while such an order stands
        self.lineup: dict[int, str] = {}    # producer id -> the unit it should train next
        self.released_origins: set[str] = set()

    def update(self, f, mandates, brief) -> None:
        engine = self.field
        mine = self.mine(mandates)
        self.stockpiles = [m for m in mine if m.kind == "stockpile" and m.amount]
        for mandate in mine:
            if mandate.kind == BUILD:
                self.build_for(f, mandate, "military_plan_capacity")
        for mandate in self.stockpiles:
            if mandate.subject is None:
                cap = ARMY_STOCKPILE_CAP if from_order(mandate.origin) else 24
                size = max(2, min(cap, int(mandate.amount)))
                changed = engine.roles["combat"].plan["army_target"] != size
                self.tune("commander", army_target=size)
                self.tune("combat", army_target=size)
                if changed:
                    # As with a model plan: a sortie already mustering keeps its size.
                    if engine.goals["sortie_started"] is None or from_order(mandate.origin):
                        engine.goals["sortie_target"] = size
                    engine.next_sortie_target = size
        stance_mandate = next((m for m in mine if m.kind in ("attack", "hold")), None)
        mustering_stockpiles = [m for m in self.stockpiles if from_order(m.origin)
                                and stance_mandate is not None and m.origin == stance_mandate.origin]
        pop_released = False
        if stance_mandate is not None and stance_mandate.kind == "attack" and mustering_stockpiles:
            if stance_mandate.origin in self.released_origins or population_full_for_muster(f, mustering_stockpiles):
                self.released_origins.add(stance_mandate.origin)
                pop_released = True
        deferred_attack = (stance_mandate is not None and stance_mandate.kind == "attack"
                           and bool(mustering_stockpiles) and not pop_released)
        self._stand("hold" if deferred_attack else (stance_mandate.kind if stance_mandate else None),
                    deferred_attack=deferred_attack)
        # Moving and fighting cost nothing; this also says which producers the army lacks.
        engine._combat(f)

    def _stand(self, stance: str | None, *, deferred_attack: bool = False) -> None:
        """An order to attack sends what is ready; an order to hold keeps the army home and calls a sortie back."""
        engine, self.stance = self.field, stance
        engine.hold_army = stance == "hold"
        departed = engine.goals["sortie_departed"] is not None
        if stance == "hold" and departed:
            # The engine's own retreat: fall back to the rally point, then muster again.
            engine.goals["phase"] = "retreat"
            engine.roles["combat"].memory["retreat_until"] = engine.now + RECALL_SECONDS
            if deferred_attack:
                engine.goals["sortie_departed"] = None
        elif stance == "attack":
            if engine.roles["combat"].memory.get("retreat_until", 0) > engine.now:
                engine.roles["combat"].memory.pop("retreat_until", None)
                if engine.goals["phase"] == "retreat":
                    engine.goals["sortie_departed"] = None
                    engine.goals["phase"] = "muster"
                    departed = False
            if not departed:
                engine.goals["sortie_target"] = min(engine.goals["sortie_target"], ATTACK_NOW_FORCE)

    def draft(self, f) -> None:
        engine = self.field
        self.begin()
        self.lineup = {}
        plan = engine._production_plan(f)
        counts, siege_count, siege_target = Counter(plan["counts"]), plan["siege_count"], plan["siege_target"]
        under_attack = bool(engine.roles["commander"].memory.get("threat_ids"))
        soldiers = sum(u.get("def_id") != "villager" and u.get("def_id") not in SCOUT_TYPES for u in f.units)
        mil_pop = military_population(f)
        ordered_specific = [m for m in self.stockpiles if m.subject and from_order(m.origin) and stockpile_count(m, f) < m.amount]
        ordered_specific_units = {u for m in ordered_specific for u in ({m.subject} | later_forms(m.subject))}
        ordered_gold_needed = any(UNITS.get(m.subject, {}).get("cost", {}).get("gold", 0) > 0 for m in ordered_specific)
        army_mandate = next((m for m in self.stockpiles if m.subject is None and m.origin != ROUTINE and mil_pop < m.amount), None)
        suppress_routine = bool(ordered_specific) and not under_attack
        wanted: dict[str, dict] = {}
        for building in plan["ordered"]:
            if building.get("def_id") not in MILITARY_BUILDINGS:
                continue
            choices = engine._military_choices(f, building, counts, siege_count, siege_target)
            ordered_first = {
                u for m in self.stockpiles
                if m.subject and sum(counts[k] for k in ({m.subject} | later_forms(m.subject))) < m.amount
                for u in ({m.subject} | later_forms(m.subject))
            }
            choices.sort(key=lambda name: name not in ordered_first)
            pick = next((name for name in choices if name in DEMOLITION_UNITS or self._obtainable(f, name)), None)
            if suppress_routine and not (
                pick in ordered_specific_units or (pick in DEMOLITION_UNITS and plan["siege_needed"])
            ):
                if not (army_mandate is not None and from_order(army_mandate.origin)):
                    continue
                if ordered_gold_needed and pick and f.unit_defs.get(pick, {}).get("cost", {}).get("gold", 0) > 0:
                    continue
            free = idle_producer(building) and building["id"] not in f.producers
            # Gatherers follow the next unit this producer actually wants, not every option in its tech tree.
            demand_unit = pick or (choices[0] if choices else None)
            if demand_unit is not None:
                for resource, amount in f.unit_defs[demand_unit].get("cost", {}).items():
                    engine.demands[resource] += amount
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
            mandate = next((m for m in self.stockpiles if m.subject and name in ({m.subject} | later_forms(m.subject))), None)
            if mandate is not None:
                origin = mandate.origin
            elif army_mandate is not None:
                origin = army_mandate.origin
            else:
                origin = ROUTINE
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
                count = max(count, max(1, mandate.amount - stockpile_count(mandate, f)))
                urgency += mandate.urgency == "rush"
            elif army_mandate is not None:
                count = max(count, max(1, army_mandate.amount - mil_pop))
                urgency += army_mandate.urgency == "rush"
            self.want(("unit", name), name, definition.get("cost", {}), count=count, capacity=max(1, entry["free"]),
                      pop=int(definition.get("population", 1)) * count, urgency=urgency, rank=rank, origin=origin,
                      emergency=under_attack)
        # A unit the head of state asked for that nothing can train yet stays on the books, blocked,
        # so the premier and the player see what it is waiting for. The mandates derived from it do the work.
        for mandate in self.stockpiles:
            name = mandate.subject
            if (name not in UNITS or mandate.origin == ROUTINE
                    or stockpile_count(mandate, f) >= mandate.amount
                    or any(u in wanted for u in ({name} | later_forms(name)))):
                continue
            if from_order(mandate.origin):
                for resource, amount in UNITS[name].get("cost", {}).items():
                    engine.demands[resource] += amount
            blocked = needs_of(mandate, f)
            if blocked:
                self.want(("unit", name), name, UNITS[name].get("cost", {}),
                          count=max(1, mandate.amount - stockpile_count(mandate, f)),
                          capacity=0, needs=blocked, urgency=2 + (mandate.urgency == "rush"), rank=FIRST_FORCE_RANK,
                          origin=mandate.origin)
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
