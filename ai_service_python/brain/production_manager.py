from __future__ import annotations

from brain.command_builder import CommandContext
from brain.entity_queries import find_town_center
from brain.profile import CivAiProfile
from brain.stores import PHASE_ECO, Blackboard


class ProductionManager:
    """Minimal P4 port: train villagers during ECO."""

    def tick(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        phase: int,
    ) -> None:
        if phase <= PHASE_ECO:
            self._train_villagers(ctx, blackboard, profile)

    def _train_villagers(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
    ) -> None:
        if blackboard.villager_count >= profile.villager_target:
            return
        town_center = find_town_center(blackboard.team_buildings)
        if town_center is None:
            return
        if not bool(town_center.get("is_complete", True)):
            return
        if not bool(town_center.get("train_queue_empty", True)):
            return
        ctx.issue_train(int(town_center["id"]), "villager")
        ctx.log_decision(
            "PROD",
            f"训练村民 ({blackboard.villager_count}/{profile.villager_target})",
        )
