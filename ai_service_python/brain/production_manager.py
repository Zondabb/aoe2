from __future__ import annotations

from brain.command_builder import CommandContext
from brain.entity_queries import (
    find_complete_building,
    find_town_center,
)
from brain.game_data import UNITS, UNIT_TRAIN_BUILDING
from brain.profile_loader import CivAiProfile, civ_for_profile
from brain.stores import PHASE_ECO, Blackboard


class ProductionManager:
    """Port of scripts/systems/ai/ai_production_manager.gd."""

    def tick(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        profile_id: str,
        phase: int,
        build_manager,
    ) -> None:
        if phase <= PHASE_ECO:
            self._train_villagers(ctx, blackboard, profile, build_manager)
            build_manager.ensure_house_if_pop_blocked(ctx, blackboard, "villager")
        elif phase == 1:
            self._train_military(ctx, blackboard, profile, profile_id, build_manager)
            preferred = self._preferred_military_unit(profile_id)
            build_manager.ensure_house_if_pop_blocked(ctx, blackboard, preferred)
        else:
            self._train_military(ctx, blackboard, profile, profile_id, build_manager)
            preferred = self._preferred_military_unit(profile_id)
            build_manager.ensure_house_if_pop_blocked(ctx, blackboard, preferred)

    def _train_villagers(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        build_manager,
    ) -> None:
        if blackboard.villager_count >= profile.villager_target:
            return
        town_center = find_town_center(blackboard.team_buildings)
        if town_center is None:
            return
        if self._try_enqueue(ctx, blackboard, town_center, "villager"):
            ctx.log_decision(
                "PROD",
                f"训练村民 ({blackboard.villager_count}/{profile.villager_target})",
            )

    def _train_military(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        profile_id: str,
        build_manager,
    ) -> None:
        civ = civ_for_profile(profile_id)
        unique_unit = civ.get("unique_unit")
        if profile.unique_unit_priority and unique_unit:
            unique_building = self._find_building_for_unit(blackboard, unique_unit)
            if unique_building is not None and self._try_enqueue(
                ctx, blackboard, unique_building, unique_unit
            ):
                ctx.log_decision("PROD", f"训练特色单位 {unique_unit}")
                return
        for unit_id, target in profile.army_composition.items():
            current = self._count_unit_id(blackboard, unit_id)
            if current >= target:
                continue
            building = self._find_building_for_unit(blackboard, unit_id)
            if building is not None and self._try_enqueue(ctx, blackboard, building, unit_id):
                ctx.log_decision("PROD", f"训练 {unit_id} ({current + 1}/{target})")
                return
        barracks = find_complete_building(blackboard.team_buildings, "barracks")
        if barracks is not None and self._try_enqueue(ctx, blackboard, barracks, "swordsman"):
            ctx.log_decision("PROD", "训练 swordsman (fallback)")
            return
        archery = find_complete_building(blackboard.team_buildings, "archery_range")
        if archery is not None:
            self._try_enqueue(ctx, blackboard, archery, "archer")

    def _try_enqueue(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        building: dict,
        unit_def_id: str,
    ) -> bool:
        if not bool(building.get("is_complete", False)):
            return False
        if not bool(building.get("train_queue_empty", True)):
            return False
        unit_def = UNITS.get(unit_def_id)
        if unit_def is None:
            return False
        if not (
            blackboard.food >= unit_def["cost_food"]
            and blackboard.wood >= unit_def["cost_wood"]
            and blackboard.gold >= unit_def["cost_gold"]
        ):
            return False
        if blackboard.pop_used + unit_def["population"] > blackboard.pop_cap:
            return False
        ctx.issue_train(int(building["id"]), unit_def_id)
        return True

    def _find_building_for_unit(
        self, blackboard: Blackboard, unit_def_id: str
    ) -> dict | None:
        building_id = UNIT_TRAIN_BUILDING.get(unit_def_id)
        if building_id is None:
            return None
        return find_complete_building(blackboard.team_buildings, building_id)

    @staticmethod
    def _preferred_military_unit(profile_id: str) -> str:
        civ = civ_for_profile(profile_id)
        unique_unit = civ.get("unique_unit")
        if unique_unit:
            return str(unique_unit)
        return "swordsman"

    @staticmethod
    def _count_unit_id(blackboard: Blackboard, unit_id: str) -> int:
        count = 0
        for unit in blackboard.team_units:
            if str(unit.get("def_id", "")) == unit_id:
                count += 1
        return count
