"""Chooses the v3 runtime for a new team session."""
from __future__ import annotations

import json
import logging

from brain import runtime_settings

logger = logging.getLogger("ai_service.runtime")


def create_runtime(profile_id: str):
    """The setting is read when the session opens; a session keeps its runtime."""
    name = runtime_settings.ai_runtime()
    logger.info(json.dumps({"event": "runtime_selected", "runtime": name, "profile_id": profile_id}))
    if name == "cabinet":
        from brain.cabinet.runtime import CabinetRuntime
        return CabinetRuntime(profile_id)
    from brain.multi_agent.runtime import MultiAgentRuntime
    return MultiAgentRuntime(profile_id)
