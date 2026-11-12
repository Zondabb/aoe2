"""The premier ranks the departments' requests.

Until the model is connected (phase 3) the premier works from the rule book
below. The same rules stay as the fallback afterwards, and they tier a new
request before the model has had its say, so no request is left unattended.
"""
from __future__ import annotations

from .models import IntelBrief, Request, from_order

POSTURES = ("defend", "balanced", "pressure")


def protected(request: Request, brief: IntelBrief) -> bool:
    """Requests no ranking may push below "next": the population cap, the
    villager floor, and the general's answer to a base under attack."""
    return request.floor or request.emergency and brief.threat_level >= 3


def default_tiers(requests: list[Request], brief: IntelBrief) -> dict[str, str]:
    tiers = {}
    for request in requests:
        if protected(request, brief) or from_order(request.origin):
            tiers[request.id] = "now"
        else:
            tiers[request.id] = "next" if request.urgency >= 2 else "later"
    # Orders that compete for a resource: the latest order keeps "now".
    ordered = [r for r in requests if from_order(r.origin) and not protected(r, brief)]
    number = lambda r: int(r.origin.split("#", 1)[1])
    for request in ordered:
        if any(number(other) > number(request) and set(other.remaining) & set(request.remaining) for other in ordered):
            tiers[request.id] = "next"
    return tiers


def apply_floors(tiers: dict[str, str], requests: list[Request], brief: IntelBrief) -> dict[str, str]:
    """Raise protected requests a ranking left at "later" or "hold" to "next"."""
    return {r.id: "next" if protected(r, brief) and tiers.get(r.id, "later") in ("later", "hold") else tiers.get(r.id, "later")
            for r in requests}


class Premier:
    def __init__(self) -> None:
        self.tiers: dict[str, str] = {}
        self.posture = "balanced"
        self.source = "rules"

    def rank(self, requests: list[Request], brief: IntelBrief) -> dict[str, str]:
        self.tiers = apply_floors(default_tiers(requests, brief), requests, brief)
        return self.tiers

    def status(self, match_over: bool = False) -> dict:
        return {"status": "complete" if match_over else "running", "reason": "default_ranking_rules", "source": self.source,
                "posture": self.posture, "tiers": dict(self.tiers)}
