from __future__ import annotations

from typing import Any

from brain.army_manager import ArmyManager
from brain.build_manager import BuildManager
from brain.combat_manager import CombatManager
from brain.command_builder import CommandContext
from brain.economy_manager import EconomyManager
from brain.land_progression import LandProgression
from brain.production_manager import ProductionManager
from brain.scout_manager import ScoutManager
from brain.profile_loader import CivAiProfile, profile_for_id
from brain.stores import (
    PHASE_ATTACK,
    PHASE_BOOM,
    PHASE_DEFEND,
    PHASE_ECO,
    Blackboard,
    EventStore,
    ObservationStore,
)
from protocol.models import TickResponse


class AiDirector:
    """Python port of scripts/systems/ai/ai_director.gd (full manager schedule)."""

    def __init__(self, profile_id: str) -> None:
        self.profile_id = profile_id or "default"
        self.profile = profile_for_id(self.profile_id)
        self.phase = PHASE_ECO
        self._previous_phase = PHASE_ECO
        self._next_build_slot = 0
        self._economy = EconomyManager()
        self._land_progression = LandProgression()
        self._build = BuildManager()
        self._production = ProductionManager()
        self._army = ArmyManager()
        self._combat = CombatManager()
        self._scout = ScoutManager()
        self._event_store = EventStore()
        self._blackboard = Blackboard()

    def reset(self) -> None:
        self.phase = PHASE_ECO
        self._previous_phase = PHASE_ECO
        self._next_build_slot = 0
        self._event_store.clear()
        self._scout.reset()
        self._economy.reset()
        self._army.reset()

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

        ctx = CommandContext(tick=tick, next_build_slot=self._next_build_slot)
        self._update_phase(ctx)

        self._economy.assign_builders(ctx, self._blackboard)

        if self._blackboard.progression:
            self._land_progression.tick(ctx, self._blackboard, self.profile)
        elif self.phase == PHASE_ECO:
            self._build.tick(ctx, self._blackboard, self.profile, self.profile_id, self.phase)
            self._production.tick(
                ctx,
                self._blackboard,
                self.profile,
                self.profile_id,
                self.phase,
                self._build,
            )
        elif self.phase == PHASE_BOOM:
            self._build.tick(ctx, self._blackboard, self.profile, self.profile_id, self.phase)
            self._production.tick(
                ctx,
                self._blackboard,
                self.profile,
                self.profile_id,
                self.phase,
                self._build,
            )
        elif self.phase == PHASE_ATTACK:
            self._production.tick(
                ctx,
                self._blackboard,
                self.profile,
                self.profile_id,
                self.phase,
                self._build,
            )
        elif self.phase == PHASE_DEFEND:
            self._build.tick(ctx, self._blackboard, self.profile, self.profile_id, self.phase)
            self._production.tick(
                ctx,
                self._blackboard,
                self.profile,
                self.profile_id,
                self.phase,
                self._build,
            )
        if self.phase in (PHASE_ATTACK, PHASE_DEFEND):
            engaged = self._combat.tick_army(
                ctx, self._blackboard, self.profile, enemy_team, self.phase
            )
            if self.phase == PHASE_DEFEND:
                self._army.rally_to_base(ctx, self._blackboard, self.profile, engaged)
            else:
                self._army.rally(ctx, self._blackboard, self.profile, engaged)
        self._economy.assign_gatherers(ctx, self._blackboard, self.profile, self.phase)
        self._scout.tick(ctx, self._blackboard, self.phase)
        self._next_build_slot = ctx.next_build_slot
        return TickResponse(
            match_id=match_id,
            team=team,
            for_tick=tick,
            commands=ctx.commands,
            debug=ctx.debug,
        )

    def _update_phase(self, ctx: CommandContext) -> None:
        bb = self._blackboard
        profile = self.profile

        # Raids must be answered during the opening as well as during attacks.
        if bb.threat_near_base:
            self._set_phase(PHASE_DEFEND, ctx)
            return

        military_ready = (
            bb.military_count >= profile.military_attack_count
            or bb.match_time >= profile.attack_time_seconds
        )
        if self.phase == PHASE_ATTACK:
            return

        if self.phase == PHASE_DEFEND:
            self._set_phase(PHASE_ATTACK if military_ready else PHASE_BOOM, ctx)
            return

        if military_ready:
            self._set_phase(PHASE_ATTACK, ctx)
            return

        eco_ready = (
            bb.villager_count >= profile.villager_target
            or bb.food >= profile.high_food_stockpile
        )
        if self.phase == PHASE_ECO and eco_ready:
            self._set_phase(PHASE_BOOM, ctx)

    def _set_phase(self, new_phase: int, ctx: CommandContext) -> None:
        if new_phase == self.phase:
            return
        self._previous_phase = self.phase
        self.phase = new_phase
        ctx.log_decision(
            "PHASE",
            f"{self._phase_name(self._previous_phase)} → {self._phase_name(new_phase)}",
        )

    @staticmethod
    def _phase_name(phase: int) -> str:
        names = {PHASE_ECO: "ECO", PHASE_BOOM: "BOOM", PHASE_ATTACK: "ATTACK", PHASE_DEFEND: "DEFEND"}
        return names.get(phase, str(phase))
