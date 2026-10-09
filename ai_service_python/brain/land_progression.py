"""Rules for catalog-based matches; the observation remains authoritative for unlocks."""
from __future__ import annotations

import json
from pathlib import Path

from brain.build_placement import next_build_position
from brain.command_builder import CommandContext
from brain.entity_queries import find_town_center, idle_villager
from brain.profile_loader import CivAiProfile
from brain.stores import Blackboard
from protocol.models import Command

CATALOG = json.loads((Path(__file__).resolve().parents[1] / "data/land_catalog.json").read_text(encoding="utf-8"))
AGE_COSTS = ({"food": 500}, {"food": 800, "gold": 200}, {"food": 1000, "gold": 800})
PREREQUISITES = (("mill", "lumber_camp"), ("blacksmith", "market"), ("monastery", "university"))


class LandProgression:
    def tick(self, ctx: CommandContext, bb: Blackboard, profile: CivAiProfile) -> None:
        age = int(bb.progression["age"])
        researching_age = bool(bb.progression.get("age_research"))
        tc = find_town_center(bb.team_buildings)
        busy: set[int] = set()
        if tc and age < 3 and not researching_age and tc.get("age_upgrade_reason") == "":
            self._research(ctx, "research_age", int(tc["id"]))
            self._spend(bb, AGE_COSTS[age])
            busy.add(int(tc["id"]))
            researching_age = True

        if age < 3 and not researching_age and bb.incomplete_buildings == 0:
            for name in PREREQUISITES[age]:
                if not any(b.get("def_id") == name for b in bb.team_buildings):
                    self._build(ctx, bb, profile, name)
                    break

        # Keep enough resources for the next age once the first eight villagers exist.
        reserve = AGE_COSTS[age] if age < 3 and not researching_age else {}
        if bb.pop_used >= bb.pop_cap:
            self._build(ctx, bb, profile, "house", repeat=True)
        self._ensure_food_supply(ctx, bb, profile)
        for name in ("barracks", "archery_range", "stable", "castle", "siege_workshop"):
            if not any(b.get("def_id") == name for b in bb.team_buildings):
                self._build(ctx, bb, profile, name)

        if age >= 1 and (researching_age or age == 3):
            for building in bb.team_buildings:
                for option in building.get("technologies", []):
                    tech = CATALOG["technologies"].get(option.get("id"), {})
                    if option.get("reason") == "" and int(building["id"]) not in busy and self._can_afford(bb, tech.get("cost", {})):
                        self._research(ctx, "research_technology", int(building["id"]), str(option["id"]))
                        self._spend(bb, tech.get("cost", {}))
                        busy.add(int(building["id"]))
                        break

        for building in bb.team_buildings:
            if not building.get("is_complete") or building.get("is_researching", False) or not building.get("train_queue_empty", True) or int(building["id"]) in busy:
                continue
            if building.get("def_id") == "town_center" and researching_age:
                continue
            for name in building.get("trainable", []):
                unit = CATALOG["units"].get(name)
                if not unit or (name == "villager" and bb.villager_count >= profile.villager_target):
                    continue
                if name != "villager" and float(unit.get("attack", 0)) <= 0:
                    continue
                cost = unit.get("cost", {})
                reserved = {} if name == "villager" and bb.villager_count < 8 else reserve
                required = {r: cost.get(r, 0) + reserved.get(r, 0) for r in ("food", "wood", "gold", "stone")}
                population = int(unit.get("population", 1))
                if not self._can_afford(bb, required) or bb.pop_used + population > bb.pop_cap:
                    continue
                ctx.issue_train(int(building["id"]), name)
                self._spend(bb, cost)
                bb.pop_used += population
                break

    def _ensure_food_supply(self, ctx: CommandContext, bb: Blackboard, profile: CivAiProfile) -> bool:
        if not any(b.get("def_id") == "mill" and b.get("is_complete") for b in bb.team_buildings):
            return False
        tc = find_town_center(bb.team_buildings)
        if tc is None:
            return False
        def near_base(entity: dict) -> bool:
            pos = entity.get("pos", [0, 0])
            return sum((float(pos[i]) - float(tc["pos"][i])) ** 2 for i in (0, 1)) <= 144.0 ** 2
        natural_food = sum(max(0.0, float(r.get("amount", 0))) for r in bb.resource_nodes
                           if r.get("kind") != "building" and r.get("resource_type") == "FOOD" and near_base(r))
        if natural_food > 100.0:
            return False
        active_farms = sum(1 for b in bb.team_buildings if b.get("def_id") == "farm" and near_base(b)
                           and (not b.get("is_complete") or float(b.get("amount", 0)) > 0))
        desired = max(2, min(4, (len(bb.team_villagers) + 1) // 2))
        if active_farms >= desired:
            return False
        # Depleted plots still reserve their footprint. Existing place_building
        # commands establish a fresh, spaced plot without protocol-only reseeds.
        return self._build(ctx, bb, profile, "farm", repeat=True)

    def _build(self, ctx: CommandContext, bb: Blackboard, profile: CivAiProfile, name: str, repeat: bool = False) -> bool:
        # One foundation each observation avoids assigning the same builder twice.
        if any(c.op == "place_building" for c in ctx.commands):
            return False
        if any(b.get("def_id") == name and (not repeat or not b.get("is_complete")) for b in bb.team_buildings):
            return False
        record = CATALOG["buildings"].get(name, {})
        if not record or int(record.get("required_age", 0)) > int(bb.progression["age"]):
            return False
        if profile.civ_id not in record.get("civilizations", []):
            return False
        for prerequisite in record.get("required_buildings", []):
            if not any(b.get("def_id") == prerequisite and b.get("is_complete") for b in bb.team_buildings):
                return False
        researched = bb.progression.get("researched_technologies", {})
        if any(not researched.get(tech, False) for tech in record.get("required_techs", [])):
            return False
        if not self._can_afford(bb, record.get("cost", {})):
            return False
        # Commands emitted earlier in this decision have not changed snapshots.
        # Preserve their workers and every construction, combat or delivery job.
        reserved_workers = {c.unit_id for c in ctx.commands} | {c.builder_id for c in ctx.commands}
        available_workers = [w for w in bb.team_villagers
                             if int(w["id"]) not in reserved_workers
                             and w.get("order", "NONE") in ("NONE", "GATHER")
                             and w.get("gather_state") != "to_drop_off"
                             and float(w.get("carry_amount", 0)) <= 0.001]
        builder = idle_villager(available_workers) or next(iter(available_workers), None)
        if builder is None:
            return False
        pos = next_build_position(
            name, find_town_center(bb.team_buildings), bb.all_buildings,
            ctx.next_build_slot, CATALOG["buildings"], bb.resource_nodes, bb.map_bounds,
        )
        if pos is None:
            return False
        ctx.issue_place_building(name, list(pos), int(builder["id"]))
        self._spend(bb, record.get("cost", {}))
        return True

    @staticmethod
    def _research(ctx: CommandContext, op: str, building_id: int, technology_id: str | None = None) -> None:
        ctx.commands.append(Command(command_id=ctx._next_id(), op=op, building_id=building_id, technology_id=technology_id))

    @staticmethod
    def _can_afford(bb: Blackboard, cost: dict) -> bool:
        return all(getattr(bb, resource) >= int(amount) for resource, amount in cost.items())

    @staticmethod
    def _spend(bb: Blackboard, cost: dict) -> None:
        for resource, amount in cost.items():
            setattr(bb, resource, getattr(bb, resource) - int(amount))
