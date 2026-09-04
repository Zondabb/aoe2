# AI Protocol CHANGELOG

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
