"""Rules for catalog-based matches; the observation remains authoritative for unlocks."""
from __future__ import annotations

import json
import math
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
UNIT_LINES = (
    ("militia", "man_at_arms", "long_swordsman", "two_handed_swordsman", "champion"),
    ("spearman", "pikeman", "halberdier"),
    ("archer", "crossbowman", "arbalest"),
    ("skirmisher", "elite_skirmisher"),
    ("scout_cavalry", "light_cavalry"),
    ("knight", "cavalier", "paladin"),
    ("camel", "heavy_camel"),
    ("cavalry_archer", "heavy_cavalry_archer"),
    ("battering_ram", "capped_ram", "siege_ram"),
    ("mangonel", "onager", "siege_onager"),
    ("scorpion", "heavy_scorpion"),
    ("chu_ko_nu", "elite_chu_ko_nu"),
    ("teutonic_knight", "elite_teutonic_knight"),
)


class LandProgression:
    def tick(self, ctx: CommandContext, bb: Blackboard, profile: CivAiProfile) -> None:
        age = int(bb.progression["age"])
        researching_age = bool(bb.progression.get("age_research"))
        tc = find_town_center(bb.team_buildings)
        busy: set[int] = set()
        army_ready = bb.military_count >= profile.military_attack_count
        if (tc and age < 3 and not researching_age and tc.get("is_complete")
                and tc.get("age_upgrade_reason") == "" and not bb.threat_near_base
                and (age == 0 or army_ready) and self._can_afford(bb, AGE_COSTS[age])):
            self._research(ctx, "research_age", int(tc["id"]))
            self._spend(bb, AGE_COSTS[age])
            busy.add(int(tc["id"]))
            researching_age = True
            ctx.log_decision("RESEARCH", f"升级时代 {age} → {age + 1}")

        # Leave room before producers finish; house construction must not depend
        # on being able to afford the currently preferred military unit.
        idle_producers = sum(1 for b in bb.team_buildings
                             if b.get("is_complete") and b.get("train_queue_empty", True)
                             and any(name != "villager" and CATALOG["units"].get(name, {}).get("attack", 0) > 0
                                     for name in b.get("trainable", [])))
        if bb.pop_cap - bb.pop_used <= max(2, idle_producers):
            self._build(ctx, bb, profile, "house", repeat=True)
        self._ensure_food_supply(ctx, bb, profile)

        # An army needs its first producer before the later-age prerequisites.
        if not any(b.get("def_id") == "barracks" for b in bb.team_buildings):
            self._build(ctx, bb, profile, "barracks")
        if age < 3 and not researching_age and bb.incomplete_buildings == 0:
            for name in PREREQUISITES[age]:
                if not any(b.get("def_id") == name for b in bb.team_buildings):
                    self._build(ctx, bb, profile, name)
                    break

        reserve = self._age_reserve(bb, profile, age, researching_age)
        for name in ("archery_range", "stable", "castle", "siege_workshop"):
            if not any(b.get("def_id") == name for b in bb.team_buildings):
                self._build(ctx, bb, profile, name)

        producers = sorted(bb.team_buildings, key=lambda b: bool(bb.threat_near_base) and b.get("def_id") == "town_center")
        for building in producers:
            if not building.get("is_complete") or building.get("is_researching", False) or not building.get("train_queue_empty", True) or int(building["id"]) in busy:
                continue
            if building.get("def_id") == "town_center" and researching_age:
                continue
            for name in self._training_candidates(building, bb, profile):
                unit = CATALOG["units"].get(name)
                if not unit or (name == "villager" and bb.villager_count >= profile.villagers_for_age(age)):
                    continue
                cost = unit.get("cost", {})
                required = self._with_reserve(cost, reserve)
                population = int(unit.get("population", 1))
                if not self._can_afford(bb, required) or bb.pop_used + population > bb.pop_cap:
                    continue
                ctx.issue_train(int(building["id"]), name)
                self._spend(bb, cost)
                bb.pop_used += population
                busy.add(int(building["id"]))
                ctx.log_decision("PROD", f"训练 {name}")
                break

        # Build a usable force before upgrades. Spend only surplus after all idle
        # producers have had a chance to train and never occupy those producers.
        if age >= 1 and army_ready and not bb.threat_near_base:
            for building in bb.team_buildings:
                if int(building["id"]) in busy or not building.get("is_complete") or building.get("is_researching") or not building.get("train_queue_empty", True):
                    continue
                for option in building.get("technologies", []):
                    tech_id = str(option.get("id", ""))
                    tech = CATALOG["technologies"].get(tech_id)
                    if not tech or option.get("reason") != "" or not self._useful_technology(tech_id, bb):
                        continue
                    if self._can_afford(bb, self._with_reserve(tech.get("cost", {}), reserve)):
                        self._research(ctx, "research_technology", int(building["id"]), tech_id)
                        self._spend(bb, tech.get("cost", {}))
                        ctx.log_decision("RESEARCH", f"研发 {tech_id}")
                        return

    @staticmethod
    def _with_reserve(cost: dict, reserve: dict) -> dict:
        return {resource: cost.get(resource, 0) + reserve.get(resource, 0)
                for resource in ("food", "wood", "gold", "stone")}

    @staticmethod
    def _age_reserve(bb: Blackboard, profile: CivAiProfile, age: int, researching_age: bool) -> dict:
        if (age >= 3 or researching_age or bb.threat_near_base
                or bb.villager_count < profile.villagers_for_age(age)
                or bb.military_count < profile.military_attack_count):
            return {}
        if not all(any(b.get("def_id") == name and b.get("is_complete") for b in bb.team_buildings)
                   for name in PREREQUISITES[age]):
            return {}
        return AGE_COSTS[age]

    @staticmethod
    def _training_candidates(building: dict, bb: Blackboard, profile: CivAiProfile) -> list[str]:
        available = [name for name in building.get("trainable", [])
                     if name in CATALOG["units"] and name != "petard"
                     and (name == "villager" or CATALOG["units"][name].get("attack", 0) > 0)]
        unique_units = {"chu_ko_nu", "elite_chu_ko_nu", "teutonic_knight", "elite_teutonic_knight"}
        main_units = {"militia", "man_at_arms", "long_swordsman", "two_handed_swordsman", "champion",
                      "archer", "crossbowman", "arbalest", "scout_cavalry", "light_cavalry",
                      "knight", "cavalier", "paladin", "battering_ram", "capped_ram", "siege_ram"}
        # Current trainable definitions already contain the researched tier.
        # Prioritize the civ's main units, then diversify units of the same age.
        counts = {name: sum(1 for unit in bb.team_units if unit.get("def_id") == name) for name in available}
        return sorted(available, key=lambda name: (
            not (profile.unique_unit_priority and name in unique_units),
            name not in main_units,
            -int(CATALOG["units"][name].get("required_age", 0)),
            counts[name],
            -float(CATALOG["units"][name].get("attack", 0)),
        ))

    @staticmethod
    def _useful_technology(tech_id: str, bb: Blackboard) -> bool:
        for line in UNIT_LINES:
            if tech_id in line:
                return any(unit.get("def_id") in line for unit in bb.team_units)
        if tech_id == "heavy_cav_archer":
            return any(unit.get("def_id") == "cavalry_archer" for unit in bb.team_units)
        return tech_id == "chemistry" and any(b.get("def_id") in ("archery_range", "siege_workshop") for b in bb.team_buildings)

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
        food_ratio = 0.5 if int(bb.progression.get("age", 0)) == 0 else 0.4
        desired = max(2, min(10, math.ceil(len(bb.team_villagers) * food_ratio)))
        if not all(any(b.get("def_id") == name and b.get("is_complete") for b in bb.team_buildings)
                   for name in ("lumber_camp", "barracks")):
            # One plot bridges the opening food shortage. Additional farms must
            # not repeatedly spend the wood needed to start military production.
            desired = 1
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
            bb.placement_visibility,
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
