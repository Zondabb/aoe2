from __future__ import annotations

from brain.command_builder import CommandContext
from brain.profile_loader import CivAiProfile
from brain.stores import ORDER_BUILD, ORDER_GATHER, Blackboard


class ArmyManager:
    """Port of scripts/systems/ai/ai_army_manager.gd."""

    def rally(self, ctx: CommandContext, blackboard: Blackboard, profile: CivAiProfile) -> None:
        if blackboard.own_tc_pos == (0.0, 0.0) or blackboard.enemy_tc_pos == (0.0, 0.0):
            return
        rally_point = (
            blackboard.own_tc_pos[0]
            + (blackboard.enemy_tc_pos[0] - blackboard.own_tc_pos[0]) * 0.35,
            blackboard.own_tc_pos[1]
            + (blackboard.enemy_tc_pos[1] - blackboard.own_tc_pos[1]) * 0.35,
        )
        rally_radius_sq = profile.rally_radius * profile.rally_radius
        rallied = 0
        for unit in blackboard.team_units:
            if str(unit.get("def_id", "")) == "villager":
                continue
            order = str(unit.get("order", ""))
            if order in (ORDER_GATHER, ORDER_BUILD):
                continue
            pos = unit.get("pos", [0.0, 0.0])
            dx = float(pos[0]) - rally_point[0]
            dy = float(pos[1]) - rally_point[1]
            if dx * dx + dy * dy > rally_radius_sq:
                if order != "MOVE":
                    ctx.issue_move(int(unit["id"]), [rally_point[0], rally_point[1]])
                    rallied += 1
        if rallied > 0:
            ctx.log_decision("ARMY", f"集结 {rallied} 单位 → {rally_point}")

    def rally_to_base(
        self, ctx: CommandContext, blackboard: Blackboard, profile: CivAiProfile
    ) -> None:
        """DEFEND: pull military units back toward own town center."""
        if blackboard.own_tc_pos == (0.0, 0.0):
            return
        rally_point = blackboard.own_tc_pos
        rally_radius_sq = profile.rally_radius * profile.rally_radius
        rallied = 0
        for unit in blackboard.team_units:
            if str(unit.get("def_id", "")) == "villager":
                continue
            order = str(unit.get("order", ""))
            if order in (ORDER_GATHER, ORDER_BUILD):
                continue
            pos = unit.get("pos", [0.0, 0.0])
            dx = float(pos[0]) - rally_point[0]
            dy = float(pos[1]) - rally_point[1]
            if dx * dx + dy * dy > rally_radius_sq:
                if order != "MOVE":
                    ctx.issue_move(int(unit["id"]), [rally_point[0], rally_point[1]])
                    rallied += 1
        if rallied > 0:
            ctx.log_decision("ARMY", f"回防 {rallied} 单位 → {rally_point}")
