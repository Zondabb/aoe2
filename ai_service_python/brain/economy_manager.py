from __future__ import annotations

import math
from typing import Any

from brain.command_builder import CommandContext
from brain.entity_queries import (
    any_villager,
    idle_villager,
    nearest_any_resource_near_base,
    nearest_resource_near_base,
)
from brain.profile_loader import CivAiProfile
from brain.stores import (
    BASE_RESOURCE_RADIUS,
    FOOD,
    GOLD,
    ORDER_BUILD,
    ORDER_GATHER,
    ORDER_NONE,
    PHASE_ECO,
    STUCK_GATHER_FRAMES,
    WOOD,
    Blackboard,
    resource_name,
    resource_type_from_name,
)


class EconomyManager:
    """Port of scripts/systems/ai/ai_economy_manager.gd."""

    def assign_builders(self, ctx: CommandContext, blackboard: Blackboard) -> None:
        for building in blackboard.team_buildings:
            if bool(building.get("is_complete", False)):
                continue
            building_id = int(building["id"])
            assigned_builder: dict[str, Any] | None = None
            for villager in blackboard.team_villagers:
                if str(villager.get("order", "")) != ORDER_BUILD:
                    continue
                if int(villager.get("target_id", -1)) != building_id:
                    continue
                assigned_builder = villager
                if int(villager.get("stuck_frames", 0)) >= STUCK_GATHER_FRAMES:
                    ctx.issue_build(int(villager["id"]), building_id)
                    ctx.log_decision(
                        "ECON",
                        f"重建路径建造 {building.get('def_id', 'building')}",
                    )
                break
            if assigned_builder is not None:
                continue
            idle = idle_villager(blackboard.team_villagers)
            if idle is not None:
                ctx.issue_build(int(idle["id"]), building_id)
                ctx.log_decision(
                    "ECON",
                    f"派村民建造 {building.get('def_id', 'building')}",
                )

    def assign_gatherers(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        phase: int,
    ) -> None:
        needs_work = self._villagers_needing_gather(blackboard)
        if not needs_work:
            return
        if phase <= PHASE_ECO:
            self._assign_opening_gatherers(ctx, blackboard, needs_work)
        else:
            self._assign_balanced_gatherers(ctx, blackboard, profile, phase, needs_work)

    def _villagers_needing_gather(self, blackboard: Blackboard) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for villager in blackboard.team_villagers:
            order = str(villager.get("order", ORDER_NONE))
            if order == ORDER_BUILD:
                continue
            if order == ORDER_GATHER and str(villager.get("gather_state", "")) == "to_drop_off":
                continue
            if order == ORDER_NONE:
                result.append(villager)
                continue
            if order != ORDER_GATHER:
                continue
            resource = villager.get("_last_resource")
            if resource is None:
                result.append(villager)
                continue
            if float(resource.get("amount", 0.0)) <= 0.0:
                result.append(villager)
                continue
            if int(villager.get("stuck_frames", 0)) >= STUCK_GATHER_FRAMES:
                result.append(villager)
        return result

    def _assign_opening_gatherers(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        villagers: list[dict[str, Any]],
    ) -> None:
        base_pos = blackboard.own_tc_pos
        for villager in villagers:
            resource = _pick_gather_target(blackboard, villager, FOOD, base_pos)
            if resource is None:
                continue
            ctx.issue_gather(int(villager["id"]), int(resource["id"]))
            resource_type = resource_type_from_name(str(resource.get("resource_type", "")))
            ctx.log_decision("ECON", f"开局采集 {resource_name(resource_type)}")

    def _assign_balanced_gatherers(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        phase: int,
        villagers: list[dict[str, Any]],
    ) -> None:
        ratios = profile.ratios_for_phase(phase)
        counts = self._count_active_gatherers(blackboard)
        assigned = _total_gather_count(counts)
        base_pos = blackboard.own_tc_pos

        for villager in villagers:
            total = assigned + 1
            target_type = _underfilled_resource_type(counts, total, ratios)
            resource = _pick_gather_target(blackboard, villager, target_type, base_pos)
            if resource is None:
                continue
            ctx.issue_gather(int(villager["id"]), int(resource["id"]))
            resource_type = resource_type_from_name(str(resource.get("resource_type", "")))
            counts[resource_type] = counts.get(resource_type, 0) + 1
            assigned += 1
            ctx.log_decision("ECON", f"村民采集 {resource_name(resource_type)}")

    def _count_active_gatherers(self, blackboard: Blackboard) -> dict[int, int]:
        counts = {FOOD: 0, WOOD: 0, GOLD: 0}
        for villager in blackboard.team_villagers:
            if str(villager.get("order", "")) != ORDER_GATHER:
                continue
            resource = villager.get("_last_resource")
            if resource is None:
                continue
            resource_type = resource_type_from_name(str(resource.get("resource_type", "")))
            counts[resource_type] = counts.get(resource_type, 0) + 1
        return counts


def _pick_gather_target(
    blackboard: Blackboard,
    villager: dict[str, Any],
    preferred_type: int,
    base_pos: tuple[float, float],
) -> dict[str, Any] | None:
    resource = nearest_resource_near_base(
        villager,
        blackboard.resource_nodes,
        preferred_type,
        base_pos,
        BASE_RESOURCE_RADIUS,
    )
    if resource is not None:
        return resource
    for resource_type in (WOOD, GOLD, FOOD):
        if resource_type == preferred_type:
            continue
        resource = nearest_resource_near_base(
            villager,
            blackboard.resource_nodes,
            resource_type,
            base_pos,
            BASE_RESOURCE_RADIUS,
        )
        if resource is not None:
            return resource
    return nearest_any_resource_near_base(
        villager,
        blackboard.resource_nodes,
        base_pos,
        BASE_RESOURCE_RADIUS,
    )


def _total_gather_count(counts: dict[int, int]) -> int:
    return counts.get(FOOD, 0) + counts.get(WOOD, 0) + counts.get(GOLD, 0)


def _underfilled_resource_type(
    counts: dict[int, int], total: int, targets: dict[int, float]
) -> int:
    best_type = FOOD
    best_deficit = -math.inf
    safe_total = max(total, 1)
    for resource_type, target_ratio in targets.items():
        actual = counts.get(resource_type, 0) / safe_total
        deficit = target_ratio - actual
        if deficit > best_deficit:
            best_deficit = deficit
            best_type = resource_type
    return best_type
