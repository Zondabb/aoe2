"""Explore public map geometry without looking up unobserved resources/enemies."""
from __future__ import annotations

import math

from brain.command_builder import CommandContext
from brain.stores import Blackboard, ORDER_NONE, ORDER_MOVE, PHASE_ATTACK

RING_STEP = 24.0
WAYPOINT_SPACING = 24.0
ARRIVAL_RADIUS = 2.0
MAX_STALLED_SECONDS = 8.0


class ScoutManager:
    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.base = None
        self.bounds = None
        self.waypoints: list[tuple[float, float]] = []
        self.index = 0
        self.actor_id = None
        self.goal = None
        self.last_position = None
        self.last_progress_time = 0.0
        self.seen_types: set[str] = set()
        self.probe_stage = 0

    def tick(self, ctx: CommandContext, bb: Blackboard, phase: int) -> None:
        if not bb.progression or bb.map_bounds is None or not bb.team_buildings:
            return
        if self.base != bb.own_tc_pos or self.bounds != bb.map_bounds:
            self.reset()
            self.base, self.bounds = bb.own_tc_pos, bb.map_bounds
            self._make_waypoints()
        usable = [r for r in bb.resource_nodes if float(r.get("amount", 0)) > 0]
        self.seen_types.update(str(r.get("resource_type", "")).upper() for r in usable)
        scouts = [u for u in bb.team_units if u.get("def_id") in ("scout_cavalry", "light_cavalry")]
        commanded = {c.unit_id for c in ctx.commands} | {c.builder_id for c in ctx.commands}
        candidates = scouts if scouts else (bb.team_villagers if not usable else [])
        actor = next((u for u in candidates if self._available(u) and int(u["id"]) not in commanded), None)
        if actor is None:
            return
        position = tuple(map(float, actor["pos"]))
        if self.actor_id != int(actor["id"]):
            self.actor_id = int(actor["id"])
            self.goal = None
            self.last_position = position
            self.last_progress_time = bb.match_time
        if math.dist(position, self.last_position) >= 1.0:
            self.last_position = position
            self.last_progress_time = bb.match_time
        arrived = self.goal is not None and math.dist(position, self.goal) <= ARRIVAL_RADIUS
        stalled = bb.match_time - self.last_progress_time >= MAX_STALLED_SECONDS
        if self.goal is not None and not arrived and not stalled and actor.get("order") == ORDER_MOVE:
            return
        goal = self._next_goal(bb, phase)
        if goal is None:
            return
        self.goal = goal
        self.last_position = position
        self.last_progress_time = bb.match_time
        ctx.issue_move(int(actor["id"]), list(goal))
        ctx.log_decision("SCOUT", f"探索公开地图坐标 {goal}")

    def _available(self, actor: dict) -> bool:
        return actor.get("order", ORDER_NONE) == ORDER_NONE or (actor.get("order") == ORDER_MOVE and int(actor["id"]) == self.actor_id)

    def _next_goal(self, bb: Blackboard, phase: int) -> tuple[float, float] | None:
        if phase == PHASE_ATTACK and len(self.seen_types) == 4 and self.probe_stage < 2 and bb.enemy_tc_pos == (0.0, 0.0):
            center = ((self.bounds[0] + self.bounds[2]) / 2, (self.bounds[1] + self.bounds[3]) / 2)
            point = center if self.probe_stage == 0 else (2 * center[0] - self.base[0], 2 * center[1] - self.base[1])
            self.probe_stage += 1
            return self._clamp(point)
        while self.index < len(self.waypoints):
            point = self.waypoints[self.index]
            self.index += 1
            blocked = False
            for resource in bb.resource_nodes:
                kind = str(resource.get("resource_type", "")).upper()
                if kind == "FOOD":
                    continue
                half = (0.6 if kind == "WOOD" else 1.0) + 1.0
                pos = resource["pos"]
                if abs(float(pos[0]) - point[0]) <= half and abs(float(pos[1]) - point[1]) <= half:
                    blocked = True
                    break
            if not blocked:
                return point
        return None

    def _make_waypoints(self) -> None:
        x0, y0, x1, y1 = self.bounds
        start_angle = math.atan2((y0 + y1) / 2 - self.base[1], (x0 + x1) / 2 - self.base[0])
        max_radius = max(math.dist(self.base, c) for c in ((x0, y0), (x0, y1), (x1, y0), (x1, y1)))
        used = set()
        for ring in range(1, math.ceil(max_radius / RING_STEP) + 1):
            radius = ring * RING_STEP
            sectors = max(8, math.ceil(math.tau * radius / WAYPOINT_SPACING))
            for sector in range(sectors):
                angle = start_angle + math.tau * sector / sectors
                point = self._clamp((self.base[0] + math.cos(angle) * radius, self.base[1] + math.sin(angle) * radius))
                key = tuple(round(value) for value in point)
                if key not in used:
                    used.add(key)
                    self.waypoints.append(point)

    def _clamp(self, point: tuple[float, float]) -> tuple[float, float]:
        return max(self.bounds[0] + 2, min(point[0], self.bounds[2] - 2)), max(self.bounds[1] + 2, min(point[1], self.bounds[3] - 2))
