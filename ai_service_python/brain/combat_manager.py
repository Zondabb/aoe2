from __future__ import annotations

from brain.command_builder import CommandContext
from brain.entity_queries import find_enemy_town_center, nearest_hostile_in_radius
from brain.profile_loader import CivAiProfile
from brain.stores import ORDER_ATTACK, ORDER_BUILD, ORDER_GATHER, Blackboard


class CombatManager:
    """Port of scripts/systems/ai/ai_combat_manager.gd."""

    def tick_army(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        enemy_team: int,
    ) -> None:
        enemy_tc = find_enemy_town_center(blackboard.all_entities, enemy_team)
        attacks = 0
        for unit in blackboard.team_units:
            if str(unit.get("def_id", "")) == "villager":
                continue
            order = str(unit.get("order", ""))
            if order in (ORDER_GATHER, ORDER_BUILD):
                continue
            nearby = nearest_hostile_in_radius(
                unit,
                blackboard.all_entities,
                enemy_team,
                profile.retarget_radius,
            )
            if nearby is not None:
                target_id = int(nearby["id"])
                if order != ORDER_ATTACK or int(unit.get("target_id", -1)) != target_id:
                    ctx.issue_attack(int(unit["id"]), target_id)
                    attacks += 1
                continue
            if enemy_tc is not None:
                target_id = int(enemy_tc["id"])
                if order != ORDER_ATTACK or int(unit.get("target_id", -1)) != target_id:
                    ctx.issue_attack(int(unit["id"]), target_id)
                    attacks += 1
            elif blackboard.enemy_tc_pos != (0.0, 0.0):
                ctx.issue_move(
                    int(unit["id"]),
                    [blackboard.enemy_tc_pos[0], blackboard.enemy_tc_pos[1]],
                )
        if attacks > 0:
            ctx.log_decision("COMBAT", f"下达 {attacks} 个攻击命令")
