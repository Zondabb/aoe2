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
    STONE,
    WOOD,
    Blackboard,
    resource_name,
    resource_type_from_name,
)


class EconomyManager:
    """Port of scripts/systems/ai/ai_economy_manager.gd."""

    def __init__(self) -> None:
        self._seen_resource_types: dict[int, int] = {}

    def reset(self) -> None:
        self._seen_resource_types.clear()

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
        for resource in blackboard.resource_nodes:
            self._seen_resource_types[int(resource["id"])] = resource_type_from_name(str(resource.get("resource_type", "")))
        needs_work = self._villagers_needing_gather(blackboard)
        if not needs_work:
            if blackboard.progression and blackboard.map_bounds:
                self._rebalance_discovered_type(ctx, blackboard)
            return
        if phase <= PHASE_ECO and not blackboard.progression:
            self._assign_opening_gatherers(ctx, blackboard, needs_work)
        else:
            self._assign_balanced_gatherers(ctx, blackboard, profile, phase, needs_work)

    def _rebalance_discovered_type(self, ctx: CommandContext, bb: Blackboard) -> None:
        """Preserve deliveries and the last worker of each existing resource kind."""
        counts = self._count_active_gatherers(bb)
        reserved = {c.unit_id for c in ctx.commands} | {c.builder_id for c in ctx.commands}
        for kind in (FOOD, WOOD, GOLD, STONE):
            if counts.get(kind, 0) > 0:
                continue
            for worker in bb.team_villagers:
                if worker.get("order") != ORDER_GATHER or worker.get("gather_state") == "to_drop_off" or float(worker.get("carry_amount", 0)) > 0.001 or int(worker["id"]) in reserved:
                    continue
                previous_type = self._worker_resource_type(worker)
                if previous_type is None or counts.get(previous_type, 0) < 2:
                    continue
                target = nearest_resource_near_base(worker, bb.resource_nodes, kind, bb.own_tc_pos, BASE_RESOURCE_RADIUS)
                if target is None:
                    continue
                ctx.issue_gather(int(worker["id"]), int(target["id"]))
                ctx.log_decision("ECON", f"调配空手村民采集新发现的 {resource_name(kind)}")
                return

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
                # A current order owns its remembered location. Absence from a
                # fog-filtered observation does not mean that node was depleted.
                if blackboard.progression and blackboard.map_bounds and villager.get("last_resource_id") is not None:
                    continue
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
        if blackboard.progression:
            ratios = {FOOD: 0.5, WOOD: 0.3, GOLD: 0.1, STONE: 0.1} if int(blackboard.progression.get("age", 0)) == 0 else {FOOD: 0.4, WOOD: 0.25, GOLD: 0.25, STONE: 0.1}
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
        counts = {FOOD: 0, WOOD: 0, GOLD: 0, STONE: 0}
        for villager in blackboard.team_villagers:
            if str(villager.get("order", "")) != ORDER_GATHER:
                continue
            resource_type = self._worker_resource_type(villager)
            if resource_type is None:
                continue
            counts[resource_type] = counts.get(resource_type, 0) + 1
        return counts

    def _worker_resource_type(self, worker: dict[str, Any]) -> int | None:
        resource = worker.get("_last_resource")
        if resource is not None:
            return resource_type_from_name(str(resource.get("resource_type", "")))
        previous_id = worker.get("last_resource_id")
        return self._seen_resource_types.get(int(previous_id)) if previous_id is not None else None


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
    return sum(counts.values())


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
