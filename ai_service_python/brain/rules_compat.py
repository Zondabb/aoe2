from __future__ import annotations

from protocol.models import (
    ChatCompletionChoice,
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatFinishReason,
    ChatMessage,
    ChatUsage,
    Observation,
    TickRequest,
    TickResponse,
)

from brain.tool_call_mapper import commands_to_tool_calls


def metadata_enemy_team(req: ChatCompletionRequest) -> int:
    if req.metadata.enemy_team is not None:
        return int(req.metadata.enemy_team)
    return 0 if req.metadata.team != 0 else 1


def observation_or_error(req: ChatCompletionRequest) -> Observation | None:
    return req.observation


def to_tick_request(req: ChatCompletionRequest, match_id: str) -> TickRequest:
    meta = req.metadata
    assert req.observation is not None
    return TickRequest(
        protocol_version=1,
        match_id=match_id,
        team=meta.team,
        team_label=meta.team_label,
        tick=meta.tick,
        time_sec=meta.time_sec,
        profile_id=meta.profile_id,
        enemy_team=metadata_enemy_team(req),
        events=req.events,
        observation=req.observation,
    )


def wrap_tick_response(
    tick_response: TickResponse,
    model: str,
    completion_id: str,
) -> ChatCompletionResponse:
    tool_calls = commands_to_tool_calls(tick_response.commands)
    finish: ChatFinishReason = "tool_calls" if tool_calls else "stop"
    return ChatCompletionResponse(
        id=completion_id,
        model=model or "aoe2-rules-v1",
        choices=[
            ChatCompletionChoice(
                index=0,
                finish_reason=finish,
                message=ChatMessage(
                    role="assistant",
                    content=None,
                    tool_calls=tool_calls or None,
                ),
            )
        ],
        usage=ChatUsage(),
        debug=list(tick_response.debug),
    )
