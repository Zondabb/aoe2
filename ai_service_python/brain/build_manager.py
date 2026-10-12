from __future__ import annotations

from brain.build_placement import next_build_position
from brain.command_builder import CommandContext
from brain.entity_queries import (
    any_villager,
    find_town_center,
    has_building,
    has_incomplete_building,
    idle_villager,
)
from brain.game_data import BUILDINGS, UNITS
from brain.profile_loader import CivAiProfile
from brain.stores import PHASE_ECO, Blackboard


class BuildManager:
    """Port of scripts/systems/ai/ai_build_manager.gd (place_building commands only)."""

    def tick(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        profile_id: str,
        phase: int,
    ) -> None:
        if phase <= PHASE_ECO:
            return
        self._tick_build_order(ctx, blackboard, profile)
        if phase >= 1:
            self._ensure_military_buildings(ctx, blackboard, profile_id)

    def ensure_house_if_pop_blocked(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        unit_def_id: str,
    ) -> None:
        unit_def = UNITS.get(unit_def_id)
        if unit_def is None:
            return
        if not self._can_afford(
            blackboard,
            unit_def["cost_food"],
            unit_def["cost_wood"],
            unit_def["cost_gold"],
        ):
            return
        if self._can_train(blackboard, unit_def["population"]):
            return
        self.ensure_building(ctx, blackboard, "house")

    def ensure_building(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        building_def_id: str,
    ) -> bool:
        # A captured foundation is absent from this observation's blockers.
        # Plan another building only after the game applies it and sends a tick.
        if any(command.op == "place_building" for command in ctx.commands):
            return False
        building_def = BUILDINGS.get(building_def_id)
        if building_def is None:
            return False
        if building_def_id != "house" and has_building(
            blackboard.team_buildings, building_def_id
        ):
            return False
        if has_incomplete_building(blackboard.team_buildings, building_def_id):
            return False
        if not self._can_afford(
            blackboard,
            building_def["cost_food"],
            building_def["cost_wood"],
            building_def["cost_gold"],
        ):
            return False
        builder = idle_villager(blackboard.team_villagers)
        if builder is None:
            builder = any_villager(blackboard.team_villagers)
        if builder is None:
            return False
        town_center = find_town_center(blackboard.team_buildings)
        place_position = next_build_position(
            building_def_id,
            town_center,
            blackboard.all_buildings,
            ctx.next_build_slot,
            resources=blackboard.resource_nodes,
            map_bounds=blackboard.map_bounds,
            placement_visibility=blackboard.placement_visibility,
        )
        if place_position is None:
            return False
        ctx.issue_place_building(
            building_def_id,
            [place_position[0], place_position[1]],
            int(builder["id"]),
        )
        ctx.log_decision("BUILD", f"放置 {building_def_id} @ {place_position}")
        return True

    def _tick_build_order(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
    ) -> None:
        for building_id in profile.build_order:
            if has_building(blackboard.team_buildings, building_id):
                continue
            if has_incomplete_building(blackboard.team_buildings, building_id):
                continue
            if self.ensure_building(ctx, blackboard, building_id):
                return

    def _ensure_military_buildings(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile_id: str,
    ) -> None:
        self.ensure_building(ctx, blackboard, "barracks")
        self.ensure_building(ctx, blackboard, "archery_range")
        if profile_id == "teutons":
            self.ensure_building(ctx, blackboard, "stable")

    @staticmethod
    def _can_afford(blackboard: Blackboard, food: int, wood: int, gold: int) -> bool:
        return (
            blackboard.food >= food
            and blackboard.wood >= wood
            and blackboard.gold >= gold
        )

    @staticmethod
    def _can_train(blackboard: Blackboard, population: int) -> bool:
        return blackboard.pop_used + population <= blackboard.pop_cap
