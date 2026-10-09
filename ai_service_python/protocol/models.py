from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

PROTOCOL_VERSION = 1

ResourceTypeName = Literal["FOOD", "WOOD", "GOLD", "STONE", "UNKNOWN"]
OrderName = Literal["NONE", "MOVE", "GATHER", "BUILD", "ATTACK"]
CommandOp = Literal[
    "move",
    "stop",
    "gather",
    "build",
    "attack",
    "place_building",
    "train",
    "research_age",
    "cancel_research_age",
    "research_technology",
    "cancel_technology",
    "noop",
]


class Economy(BaseModel):
    food: int
    wood: int
    gold: int
    stone: int = 0
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
    is_researching: bool = False
    trainable: list[str] | None = None
    age_upgrade_reason: str | None = None
    technologies: list[dict[str, str]] = Field(default_factory=list)
    resource_type: Literal["FOOD"] | None = None
    amount: float | None = None


class EntityResource(BaseModel):
    id: int
    kind: Literal["resource"] = "resource"
    resource_type: ResourceTypeName
    pos: list[float]
    amount: float


EntitySnapshot = EntityUnit | EntityBuilding | EntityResource


class Progression(BaseModel):
    age: int = Field(ge=0, le=3)
    researched_technologies: dict[str, bool] = Field(default_factory=dict)
    age_research: dict[str, Any] = Field(default_factory=dict)


class Observation(BaseModel):
    economy: Economy
    derived: Derived
    entities: list[dict[str, Any]]
    progression: Progression | None = None
    map_bounds: dict[str, list[float]] | None = None


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
    technology_id: str | None = None
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


class TickBatchItem(BaseModel):
    team: int
    team_label: str = ""
    tick: int
    time_sec: float
    profile_id: str = ""
    enemy_team: int = 0
    events: list[GameEvent] = Field(default_factory=list)
    observation: Observation


class TickBatchRequest(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str
    requests: list[TickBatchItem]


class TickBatchResponse(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str
    responses: list[TickResponse]


class MatchStartRequest(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str
    teams: list[dict[str, Any]] = Field(default_factory=list)


class MatchEndRequest(BaseModel):
    protocol_version: int = PROTOCOL_VERSION
    match_id: str


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"


PROTOCOL_VERSION_V2 = 2

ChatRole = Literal["system", "user", "assistant", "tool"]
ChatFinishReason = Literal["stop", "tool_calls", "length"]


class ChatMessage(BaseModel):
    role: ChatRole
    content: str | None = None
    tool_calls: list[dict[str, Any]] | None = None


class ChatToolFunction(BaseModel):
    name: str
    description: str = ""
    parameters: dict[str, Any] = Field(default_factory=dict)


class ChatTool(BaseModel):
    type: Literal["function"] = "function"
    function: ChatToolFunction


class ChatMetadata(BaseModel):
    protocol_version: int = PROTOCOL_VERSION_V2
    match_id: str = ""
    team: int = 0
    tick: int = 0
    time_sec: float = 0.0
    profile_id: str = ""
    enemy_team: int | None = None
    team_label: str = ""

    model_config = {"extra": "allow"}


class ChatCompletionRequest(BaseModel):
    model: str = "aoe2-rules-v1"
    stream: bool = False
    temperature: float = 0.0
    max_tokens: int = 2048
    messages: list[ChatMessage]
    tools: list[ChatTool] = Field(default_factory=list)
    tool_choice: str | dict[str, Any] = "auto"
    metadata: ChatMetadata = Field(default_factory=ChatMetadata)
    observation: Observation | None = None
    events: list[GameEvent] = Field(default_factory=list)


class ChatCompletionChoice(BaseModel):
    index: int = 0
    finish_reason: ChatFinishReason = "stop"
    message: ChatMessage


class ChatUsage(BaseModel):
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0


class ChatCompletionResponse(BaseModel):
    id: str
    object: Literal["chat.completion"] = "chat.completion"
    model: str = "aoe2-rules-v1"
    choices: list[ChatCompletionChoice]
    usage: ChatUsage = Field(default_factory=ChatUsage)
    debug: list[DebugEntry] = Field(default_factory=list)


class ChatCompletionBatchRequest(BaseModel):
    requests: list[ChatCompletionRequest]


class ChatCompletionBatchResponse(BaseModel):
    responses: list[ChatCompletionResponse]

