# AI Protocol CHANGELOG

## Server-owned model configuration (2026-10-23)

Godot now configures only the Python service connection and control cadence.
Provider backend, model, base URL, credentials and generation settings are owned
by the Python service configuration. Chat-shaped game requests use the fixed
`aoe2-service` model placeholder and omit provider metadata and generation knobs;
the service resolves the actual upstream model. Existing wire schemas remain
compatible with older clients; client-supplied values cannot override configured
server settings. Strategic memory stays server-side without client history.

## Additive observation fields — siege coordination (2026-10-22)

Unit `combat` snapshots and `decision_context.catalog.units` expose
`projectile_splash_radius` (simulation-world distance) and
`projectile_friendly_fire` (boolean). Executors can use these public weapon
properties to avoid attacking a location occupied by friendly escorts or
workers. Existing clients may ignore these additive fields; command and role
plan schemas are unchanged. See [siege strategy](../docs/ai_siege_strategy.md).

## v3 — Multi-agent fast control (2026-10-15)

`POST /v3/ai/tick` advances six persistent role executors without waiting for
model HTTP. Bounded asynchronous planners update role plans. The game enables
this path for external LLM opponents and player autoplay with
`multi_agent_enabled=true`. Legacy v1/v2 endpoints remain available.

- Request: existing `ChatCompletionRequest` with a required full `observation`;
  metadata adds `protocol_version=3`, string `session_epoch`, integer
  `observation_seq` equal to `tick`, and `event_delivery` sequence/gap metadata.
  `messages` and `tools` can be empty. Streaming is unsupported.
- Response: `protocol_version`, `match_id`, `team`, `session_epoch`, `for_tick`,
  `acknowledged_observation_seq`, `commands`, `debug`, `agent_status`, `goals`,
  and `planning`. This endpoint returns commands directly, not chat choices.
- Commands retain primitive operations and add session/task/observation lineage
  and `expires_at_sim_time`. Godot validates and deduplicates before execution.
- Identical observation retries return cached commands; conflicting sequence
  reuse, stale observations, closed sessions and epoch changes return HTTP 409.
  Invalid v3 envelopes return HTTP 422. Existing Bearer authentication applies.
- Events use peek/ack delivery, bounded retention and explicit gap reporting.
  Acceptance is distinct from completion; foundation IDs, production queue IDs,
  unit births, stalls and human overrides allow snapshot reconciliation.
- Observation adds `capabilities` and `victory_conditions`, plus owned production,
  research and movement details. Enemy internal state stays filtered.
- Existing `/v1/ai/match/start` and `/v1/ai/match/end` also open/close v3 state.

The implementation contract is validated by `test_multi_agent_scheduler.py`
and `run_multi_agent_gateway.gd`; setup and limitations are documented in
[the multi-agent implementation guide](../docs/multi_agent_ai.md).

## v2 — DRAFT (2026-09-04)

Non-streaming Chat Completions adapter. v1 tick endpoints stay frozen. External
LLM play now defaults to the opt-out v3 path described above.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/chat/completions` | OpenAI-style completion; `stream` must be `false` |
| POST | `/v1/chat/completions_batch` | Multi-team chat in one RTT (`requests[]` → `responses[]`) |

### Schema

Draft schema: [`ai_v2_chat.schema.json`](ai_v2_chat.schema.json)

Examples: [`examples/chat_completion_request.json`](examples/chat_completion_request.json), [`examples/chat_completion_response.json`](examples/chat_completion_response.json)

### Request notes

- `messages` is the LLM channel; optional `observation` / `events` keep v1 structured snapshots for `rules_compat`.
- `tools` names match v1 command ops: gather, train, place_building, build, move, attack, stop, noop.
- `stream: true` is rejected with HTTP 400.

### Response notes

- Primary: `choices[0].message.tool_calls`.
- Fallback: `choices[0].message.content` JSON `{ "commands": [...] }`.
- `usage` may be zeros for the rules backend.
- `backend=openai` (or env `AOE2_AI_BACKEND`) forwards messages/tools to an OpenAI-compatible API; on failure with `observation` present, falls back to rules.

### Authentication

Same Bearer token as v1 (`AOE2_AI_TOKEN`). `/health` remains unauthenticated.

---

## v1 — FROZEN (2026-09-04)

Protocol version `1` is frozen for production use. Breaking changes require `protocol_version: 2`.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Service liveness |
| POST | `/v1/ai/match/start` | Reset director state for match |
| POST | `/v1/ai/match/end` | Clear match directors |
| POST | `/v1/ai/tick` | Single-team tick |
| POST | `/v1/ai/tick_batch` | Multi-team tick (ai_vs_ai) |

### Schema

Authoritative schema: [`ai_v1.schema.json`](ai_v1.schema.json)

Examples: [`examples/tick_request.json`](examples/tick_request.json), [`examples/tick_response.json`](examples/tick_response.json)

### Authentication (optional)

When `AOE2_AI_TOKEN` is set on the server, clients must send:

```http
Authorization: Bearer <token>
```

Game side: `GameSession.ai_service_token` or env `AOE2_AI_TOKEN`.

### v1 scope

- Observation: economy, derived, entity snapshots (unit/building/resource)
- Commands: move, stop, gather, build, attack, place_building, train, noop
- Events: match_started, entity_spawned, entity_destroyed, building_completed, resource_depleted, unit_order_finished, match_ended
