from __future__ import annotations

from typing import Any

from brain.command_builder import CommandContext
from brain.economy_manager import EconomyManager
from brain.production_manager import ProductionManager
from brain.profile import CivAiProfile, profile_for_id
from brain.stores import (
    PHASE_ATTACK,
    PHASE_BOOM,
    PHASE_DEFEND,
    PHASE_ECO,
    Blackboard,
    EventStore,
    ObservationStore,
)
from protocol.models import DebugEntry, TickResponse


class AiDirector:
    """Python port of scripts/systems/ai/ai_director.gd (P4 minimal set)."""

    def __init__(self, profile_id: str) -> None:
        self.profile = profile_for_id(profile_id)
        self.phase = PHASE_ECO
        self._previous_phase = PHASE_ECO
        self._economy = EconomyManager()
        self._production = ProductionManager()
        self._event_store = EventStore()
        self._blackboard = Blackboard()

    def reset(self) -> None:
        self.phase = PHASE_ECO
        self._previous_phase = PHASE_ECO
        self._event_store.clear()

    def apply_events(self, events: list[dict[str, Any]]) -> None:
        self._event_store.apply(events)

    def evaluate(
        self,
        tick: int,
        match_id: str,
        team: int,
        enemy_team: int,
        time_sec: float,
        observation: dict[str, Any],
    ) -> TickResponse:
        store = ObservationStore()
        store.load_from_dict(observation)
        store.apply_to_blackboard(self._blackboard, team, enemy_team)
        self._blackboard.match_time = time_sec

        self._update_phase()
        ctx = CommandContext(tick=tick)

        self._economy.assign_gatherers(ctx, self._blackboard, self.profile, self.phase)
        self._production.tick(ctx, self._blackboard, self.profile, self.phase)

        return TickResponse(
            match_id=match_id,
            team=team,
            for_tick=tick,
            commands=ctx.commands,
            debug=ctx.debug,
        )

    def _update_phase(self) -> None:
        bb = self._blackboard
        profile = self.profile

        if self.phase == PHASE_ATTACK:
            if bb.threat_near_base:
                self._set_phase(PHASE_DEFEND)
            return

        if self.phase == PHASE_DEFEND:
            if not bb.threat_near_base:
                next_phase = (
                    PHASE_BOOM
                    if bb.military_count < profile.military_attack_count
                    else PHASE_ATTACK
                )
                self._set_phase(next_phase)
            return

        military_ready = (
            bb.military_count >= profile.military_attack_count
            or bb.match_time >= profile.attack_time_seconds
        )
        if military_ready:
            self._set_phase(PHASE_ATTACK)
            return

        eco_ready = (
            bb.villager_count >= profile.villager_target
            or bb.food >= profile.high_food_stockpile
        )
        if self.phase == PHASE_ECO and eco_ready:
            self._set_phase(PHASE_BOOM)

    def _set_phase(self, new_phase: int) -> None:
        if new_phase == self.phase:
            return
        self._previous_phase = self.phase
        self.phase = new_phase
