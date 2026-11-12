"""Mandates: what the head of state wants, in the form departments read.

Phase 2 has only the standing mandates every team starts with, derived from
its civilization profile. Player orders and the national policy script arrive
with the order ledger in phase 4.
"""
from __future__ import annotations

from .models import Mandate

MIN_WORKER_TARGET = 16


def default_mandates(profile) -> list[Mandate]:
    """The civilization profile as standing mandates."""
    mandates = [Mandate("economy", "worker_target", amount=max(MIN_WORKER_TARGET, int(profile.villager_target))),
                Mandate("general", "stockpile", amount=max(2, min(24, int(profile.military_attack_count))))]
    for unit, count in profile.army_composition.items():
        if isinstance(count, int) and count > 0:
            mandates.append(Mandate("general", "stockpile", subject=str(unit), amount=count))
    return mandates
