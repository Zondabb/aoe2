from __future__ import annotations

import math

from brain.command_builder import CommandContext
from brain.profile_loader import CivAiProfile
from brain.stores import ORDER_ATTACK, ORDER_BUILD, ORDER_GATHER, PHASE_ATTACK, PHASE_DEFEND, Blackboard


class CombatManager:
    """Choose one tactical target from the current, fog-filtered observation."""

    def tick_army(
        self,
        ctx: CommandContext,
        blackboard: Blackboard,
        profile: CivAiProfile,
        enemy_team: int,
        phase: int = PHASE_ATTACK,
    ) -> set[int]:
        hostiles = [
            entity for entity in blackboard.all_entities
            if entity.get("kind") in ("unit", "building")
            and int(entity.get("team", -1)) == enemy_team
            and float(entity.get("hp", 0)) > 0
            and not entity.get("is_placement_ghost", False)
        ]
        if phase == PHASE_DEFEND:
            # Distant units also respond to a raid, without chasing the enemy TC.
            hostiles = [
                entity for entity in hostiles
                if entity.get("kind") == "unit"
                and math.dist(entity["pos"], blackboard.own_tc_pos) <= profile.defend_radius
            ]
        by_id = {int(entity["id"]): entity for entity in hostiles}
        engaged: set[int] = set()
        commanded = {command.unit_id for command in ctx.commands}
        attacks = 0
        for unit in blackboard.team_units:
            unit_id = int(unit["id"])
            order = str(unit.get("order", ""))
            if unit.get("def_id") == "villager" or float(unit.get("hp", 1)) <= 0:
                continue
            if order in (ORDER_GATHER, ORDER_BUILD) or unit_id in commanded:
                continue
            current = by_id.get(int(unit.get("target_id") or -1)) if order == ORDER_ATTACK else None
            nearby = [
                entity for entity in hostiles
                if math.dist(unit["pos"], entity["pos"]) <= profile.retarget_radius
            ]
            # Fight nearby troops before buildings, but keep a live target to
            # avoid restarting attacks every time two enemies swap distances.
            troops = [entity for entity in nearby if entity.get("kind") == "unit"]
            if current in troops:
                target = current
            elif troops:
                target = min(troops, key=lambda entity: math.dist(unit["pos"], entity["pos"]))
            elif current is not None:
                target = current
            elif phase == PHASE_DEFEND:
                target = min(hostiles, key=lambda entity: math.dist(unit["pos"], entity["pos"]), default=None)
            else:
                target = min(
                    hostiles,
                    key=lambda entity: (
                        0 if entity.get("def_id") == "town_center" else 1,
                        math.dist(unit["pos"], entity["pos"]),
                    ),
                    default=None,
                )
            if target is None:
                continue
            engaged.add(unit_id)
            target_id = int(target["id"])
            if order != ORDER_ATTACK or int(unit.get("target_id") or -1) != target_id:
                ctx.issue_attack(unit_id, target_id)
                attacks += 1
        if attacks:
            ctx.log_decision("COMBAT", f"下达 {attacks} 个攻击命令")
        return engaged
