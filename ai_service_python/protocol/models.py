from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

PROTOCOL_VERSION = 1

ResourceTypeName = Literal["FOOD", "WOOD", "GOLD", "UNKNOWN"]
OrderName = Literal["NONE", "MOVE", "GATHER", "BUILD", "ATTACK"]
CommandOp = Literal[
    "move",
    "stop",
    "gather",
    "build",
    "attack",
    "place_building",
    "train",
    "noop",
]


class Economy(BaseModel):
    food: int
    wood: int
    gold: int
    pop_used: int
    pop_cap: int


class Derived(BaseModel):
    own_tc_id: int
    own_tc_pos: list[float]
    enemy_tc_id: int
    enemy_tc_pos: list[float]
    threat_near_base: bool
    villager_count: int
    military_count: int
    incomplete_buildings: int
    match_time_sec: float = 0.0


class EntityUnit(BaseModel):
    id: int
    kind: Literal["unit"] = "unit"
    def_id: str
    team: int
    pos: list[float]
    hp: float
    max_hp: float
    order: OrderName
    gather_state: str = ""
    carry_type: str | None = None
    carry_amount: float = 0.0
    stuck_frames: int = 0
    last_resource_id: int | None = None
    target_id: int | None = None


class EntityBuilding(BaseModel):
    id: int
    kind: Literal["building"] = "building"
    def_id: str
    team: int
    pos: list[float]
    hp: float
    max_hp: float
    is_complete: bool
    build_progress: float = 0.0
    train_queue_empty: bool = True


class EntityResource(BaseModel):
    id: int
    kind: Literal["resource"] = "resource"
    resource_type: ResourceTypeName
    pos: list[float]
    amount: float


EntitySnapshot = EntityUnit | EntityBuilding | EntityResource


class Observation(BaseModel):
    economy: Economy
    derived: Derived
    entities: list[dict[str, Any]]


class GameEvent(BaseModel):
    seq: int
    type: str
    entity_id: int | None = None
    entity: dict[str, Any] | None = None
    resource_type: str | None = None
    reason: str | None = None


class Command(BaseModel):
    command_id: str
    op: CommandOp
    unit_id: int | None = None
    building_id: int | None = None
    target_id: int | None = None
    building_def_id: str | None = None
    unit_def_id: str | None = None
    pos: list[float] | None = None
    builder_id: int | None = None


class DebugEntry(BaseModel):
    category: str
    message: str


class TickRequest(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str
    team: int
    team_label: str = ""
    tick: int
    time_sec: float
    profile_id: str = ""
    enemy_team: int = 0
    events: list[GameEvent] = Field(default_factory=list)
    observation: Observation


class TickResponse(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str
    team: int
    for_tick: int
    commands: list[Command]
    debug: list[DebugEntry] = Field(default_factory=list)


class MatchStartRequest(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str
    teams: list[dict[str, Any]] = Field(default_factory=list)


class MatchEndRequest(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
