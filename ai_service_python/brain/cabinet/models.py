"""What the cabinet's layers hand each other (docs/cabinet_ai_design.md)."""
from __future__ import annotations

from dataclasses import dataclass, field

RESOURCES = ("food", "wood", "gold", "stone")
DEPARTMENTS = ("economy", "intel", "general", "defense", "tech")
TIERS = ("now", "next", "later", "hold")
ROUTINE = "routine"


def order_origin(number: int) -> str:
    return f"order#{number}"


def from_order(origin: str) -> bool:
    return origin.startswith("order#")


@dataclass
class Mandate:
    """One instruction from the head of state, as a department reads it."""

    dept: str
    kind: str
    subject: str | None = None
    amount: int | None = None
    urgency: str = "normal"   # normal | rush
    origin: str = ROUTINE


@dataclass
class Request:
    """A department's claim on the treasury. Every number comes from the match catalog."""

    id: str
    dept: str
    key: tuple
    item: str
    count: int = 1
    # Total still to pay, and the part that could be spent at once: idle
    # capacity for batches, the whole price for a one-off purchase.
    remaining: dict[str, float] = field(default_factory=dict)
    tranche: dict[str, float] = field(default_factory=dict)
    pop: int = 0
    needs: tuple[str, ...] = ()
    urgency: int = 1          # the department's own view, 0..3
    rank: int = 50            # the department's order among equally urgent requests
    origin: str = ROUTINE
    floor: bool = False       # never ranked below "next", whatever the premier says
    emergency: bool = False   # answers a base under attack
    patience: float = 180.0   # seconds it may hold money without gathering more or buying before it steps back
    created_at: float = 0.0

    def line(self) -> str:
        return f"{self.item} x{self.count}" if self.count != 1 else self.item


@dataclass
class IntelBrief:
    """The intelligence group's shared picture of the enemy for this tick."""

    threat_level: int = 0     # 0 none, 1 enemy army seen, 2 approaching, 3 base under attack
    enemy_army: dict[str, int] = field(default_factory=dict)
    forecast: str = "unknown"  # ahead | even | behind | unknown
    counters: list[str] = field(default_factory=list)
    enemy_progress: dict = field(default_factory=dict)
    alerts: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {"threat_level": self.threat_level, "enemy_army": dict(self.enemy_army), "forecast": self.forecast,
                "counters": list(self.counters), "enemy_progress": dict(self.enemy_progress), "alerts": list(self.alerts)}


@dataclass
class DeptReport:
    """What a department did this tick and what it is waiting for."""

    dept: str
    status: str = "idle"      # running | waiting_funds | waiting_needs | waiting | blocked | idle | complete
    reason: str = ""
    requests: list[dict] = field(default_factory=list)
    # The seven-role engine still moves the units; its roles' own status, by role name.
    roles: dict[str, dict] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return {"status": self.status, "reason": self.reason, "requests": list(self.requests), "roles": dict(self.roles)}
