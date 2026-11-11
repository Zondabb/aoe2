"""Team-session runtime of the cabinet architecture.

Phase 0 of docs/cabinet_ai_design.md: the cabinet runtime exists and can be
selected, and every call is handed to the seven-role runtime, so selecting it
changes no command. Later phases move behaviour behind the methods below.
"""
from __future__ import annotations

from brain.multi_agent.runtime import MultiAgentRuntime
from protocol.models import ChatCompletionRequest


class CabinetRuntime:
    """What MultiAgentService drives for one team. Caller serializes mutation."""

    def __init__(self, profile_id: str = "default") -> None:
        self.legacy = MultiAgentRuntime(profile_id)

    def tick(self, req: ChatCompletionRequest) -> dict:
        return self.legacy.tick(req)

    def planning_context(self, role: str) -> dict:
        return self.legacy.planning_context(role)

    def apply_plan(self, role: str, plan: dict) -> bool:
        return self.legacy.apply_plan(role, plan)

    def load_strategic_memory(self, snapshot: dict) -> None:
        self.legacy.load_strategic_memory(snapshot)

    @property
    def goals(self) -> dict:
        return self.legacy.goals

    @property
    def match_summary(self) -> dict | None:
        return self.legacy.match_summary
