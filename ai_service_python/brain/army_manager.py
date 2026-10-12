from __future__ import annotations

import math

from brain.command_builder import CommandContext
from brain.profile_loader import CivAiProfile
from brain.stores import ORDER_ATTACK, ORDER_BUILD, ORDER_GATHER, ORDER_MOVE, Blackboard


class ArmyManager:
    """Support combat orders and search public map geometry when targets are hidden."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._search_key = None
        self._search_points: list[tuple[float, float]] = []
        self._search_index = 0
        self._search_goal = None
        self._leader_id = None
        self._leader_position = None
        self._last_progress_time = 0.0
        self._move_goals: dict[int, tuple[float, float]] = {}

    def rally(
        self, ctx: CommandContext, blackboard: Blackboard, profile: CivAiProfile,
        engaged: set[int] | None = None,
    ) -> None:
        # Combat runs first. Never turn an effective attack back into a rally
        # MOVE, even when no new attack command was needed this tick.
        reserved = (engaged or set()) | {command.unit_id for command in ctx.commands}
        candidates = [
            unit for unit in blackboard.team_units
            if unit.get("def_id") not in ("villager", "scout_cavalry", "light_cavalry")
            and float(unit.get("hp", 1)) > 0
            and int(unit["id"]) not in reserved
            and unit.get("order") not in (ORDER_GATHER, ORDER_BUILD, ORDER_ATTACK)
            and (unit.get("order") != ORDER_MOVE or int(unit["id"]) in self._move_goals)
        ]
        if not candidates or blackboard.map_bounds is None:
            return
        key = (blackboard.own_tc_pos, blackboard.map_bounds)
        if self._search_key != key:
            self.reset()
            self._search_key = key
            x0, y0, x1, y1 = blackboard.map_bounds
            center = ((x0 + x1) / 2, (y0 + y1) / 2)
            opposite = (2 * center[0] - key[0][0], 2 * center[1] - key[0][1])
            clamp = lambda point: (max(x0 + 2, min(point[0], x1 - 2)), max(y0 + 2, min(point[1], y1 - 2)))
            self._search_points = [clamp(center), clamp(opposite)]
            # A bounded sweep also works on saved maps with asymmetric spawns.
            for row in range(5):
                for col in (range(5) if row % 2 == 0 else range(4, -1, -1)):
                    point = clamp((x0 + (x1 - x0) * (col + 0.5) / 5, y0 + (y1 - y0) * (row + 0.5) / 5))
                    if point not in self._search_points:
                        self._search_points.append(point)
        leader = min(candidates, key=lambda unit: int(unit["id"]))
        position = tuple(map(float, leader["pos"]))
        if int(leader["id"]) != self._leader_id:
            self._leader_id = int(leader["id"])
            self._leader_position = position
            self._last_progress_time = blackboard.match_time
        if math.dist(position, self._leader_position) >= 1:
            self._leader_position = position
            self._last_progress_time = blackboard.match_time
        arrived = self._search_goal is not None and math.dist(position, self._search_goal) <= profile.rally_radius
        stalled = blackboard.match_time - self._last_progress_time >= 8.0
        if self._search_goal is None or arrived or stalled:
            self._search_goal = self._search_points[self._search_index % len(self._search_points)]
            self._search_index += 1
            self._last_progress_time = blackboard.match_time
            self._leader_position = position
        moved = 0
        for unit in candidates:
            if self._move(ctx, unit, self._search_goal):
                moved += 1
        if moved:
            ctx.log_decision("ARMY", f"搜索敌军 {moved} 单位 → {self._search_goal}")

    def rally_to_base(
        self, ctx: CommandContext, blackboard: Blackboard, profile: CivAiProfile,
        engaged: set[int] | None = None,
    ) -> None:
        if blackboard.own_tc_pos == (0.0, 0.0) and not blackboard.team_buildings:
            return
        reserved = (engaged or set()) | {command.unit_id for command in ctx.commands}
        rallied = 0
        for unit in blackboard.team_units:
            if unit.get("def_id") == "villager" or float(unit.get("hp", 1)) <= 0:
                continue
            if unit.get("order") in (ORDER_GATHER, ORDER_BUILD) or int(unit["id"]) in reserved:
                continue
            if math.dist(unit["pos"], blackboard.own_tc_pos) > profile.rally_radius:
                rallied += self._move(ctx, unit, blackboard.own_tc_pos)
        if rallied:
            ctx.log_decision("ARMY", f"回防 {rallied} 单位 → {blackboard.own_tc_pos}")

    def _move(self, ctx: CommandContext, unit: dict, goal: tuple[float, float]) -> bool:
        unit_id = int(unit["id"])
        if unit.get("order") == ORDER_MOVE and self._move_goals.get(unit_id) == goal:
            return False
        self._move_goals[unit_id] = goal
        ctx.issue_move(unit_id, list(goal))
        return True
