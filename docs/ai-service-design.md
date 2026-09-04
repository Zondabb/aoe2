# AI 服务分离设计

**Date:** 2026-09-04  
**Engine:** Godot 4.7  
**Status:** Design — 待实现  
**Related:** [AI 系统（进程内）](superpowers/specs/2026-08-14-ai-system-design.md)、[AI vs AI 场景](ai_vs_ai_arena.md)

## 1. 目标

将 **AI 决策** 与 **游戏仿真** 彻底分离：

| 角色 | 职责 |
|------|------|
| **游戏（Godot）** | 维护世界状态；构建观测；执行已校验命令；推送事件 |
| **AI 服务** | 接收观测与事件；输出命令批次；可用 **任意语言**（Python / Rust / GDScript 等）实现 |

**硬性约束：**

1. 游戏与 AI 之间 **只通过 HTTP + JSON** 通信（本地与远程同一协议）。
2. 开局可配置 **AI 服务地址**；未配置时使用 **本地默认服务**（`http://127.0.0.1:8765`）。
3. 本地 AI 与远程 AI **请求/响应格式完全一致**，便于切换与对照测试。
4. AI 服务 **不得** 持有 Godot 对象引用；游戏 **不得** 无条件信任 AI 返回的命令。

## 2. 现状与耦合点

当前 AI 在进程内由 `AiDirector` 驱动（`scripts/systems/ai/`），每 0.5s：

- 直接遍历 `Entities` 子节点构建 `AiBlackboard`
- 调用 `unit.call("command_gather", resource)` 等
- `AiBuildManager` 直接 `instantiate` 建筑并 `add_child`

需替换为：

```
ObservationBuilder → HTTP POST → AI Service → HTTP Response → CommandExecutor
```

现有 Manager 逻辑（Economy / Build / Production / Army / Combat）可 **整体迁入 AI 服务**，游戏侧只保留 Gateway。

## 3. 总体架构

```text
┌─────────────────────────────────────────────────────────────────┐
│                        游戏进程 (Godot)                          │
│  ┌──────────────┐   ┌─────────────────┐   ┌─────────────────┐ │
│  │ Simulation   │◄──│ CommandExecutor │◄──│ CommandValidator│ │
│  │ unit/build/  │   │ 落地 command_*  │   │ 合法性校验      │ │
│  │ resource     │   └────────▲────────┘   └────────▲────────┘ │
│  └──────┬───────┘            │                       │          │
│         │            ┌───────┴────────┐              │          │
│         │            │   AiGateway    │──────────────┘          │
│         │            │ tick 调度/重试 │                         │
│         ▼            └───────▲────────┘                         │
│  ┌──────────────┐            │ HTTP JSON                        │
│  │ EntityRegistry│           │                                  │
│  │ Observation  │────────────┘                                  │
│  │ Builder      │                                               │
│  └──────────────┘                                               │
└───────────────────────────────┬─────────────────────────────────┘
                                │ POST /v1/ai/tick
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     AI 服务（独立进程）                           │
│  Python / GDScript headless / 其他                               │
│  ┌────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ EventStore │→ │ AiDirector   │→ │ Command batch builder  │ │
│  │ + Obs      │  │ + Managers   │  │                        │ │
│  └────────────┘  └──────────────┘  └────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**数据流（每个 AI tick）：**

```text
1. 游戏仿真推进 Δt（0.5s 边界）
2. ObservationBuilder 生成 snapshot + 增量 events
3. AiGateway POST 到 AI 服务
4. AI 服务返回 command_batch
5. CommandValidator 逐条校验
6. CommandExecutor 执行合法命令
7. （可选）下一 tick 再请求；命令针对 tick N 的观测，在 tick N+1 执行
```

## 4. 配置

### 4.1 配置项

| 键 | 说明 | 默认值 |
|----|------|--------|
| `ai_service_url` | AI 服务根地址，如 `http://127.0.0.1:8765` | `http://127.0.0.1:8765` |
| `ai_service_timeout_ms` | HTTP 超时 | `3000` |
| `ai_tick_interval_sec` | 与现 `TICK_INTERVAL` 一致 | `0.5` |
| `ai_use_local_embedded` | 未配置外部 URL 时是否启动内嵌本地服务 | `true` |
| `ai_protocol_version` | 协议版本 | `1` |

### 4.2 配置入口（建议）

1. **Autoload 扩展** `GameSession`（`scripts/core/game_session.gd`）：

```gdscript
var ai_service_url := "http://127.0.0.1:8765"
var ai_service_timeout_ms := 3000
var ai_use_local_embedded := true
```

2. **文明选择 / 设置界面**（`civ_select.tscn`）：增加「AI 服务地址」输入框，写入 `GameSession` 后进入对局。

3. **命令行 / 环境变量**（可选）：`AOE2_AI_URL=http://host:8765` 覆盖 UI 配置，便于 CI 与 headless 测试。

4. **project.godot 默认值**（可选 `[ai]` custom section 或 `GameSession` 硬编码默认）。

### 4.3 本地默认行为

当 `ai_service_url` 为空或等于默认 localhost：

1. 若 `ai_use_local_embedded == true`：对局启动时由 **LocalAiServer** 在 `127.0.0.1:8765` 起 HTTP 服务（可用 GDScript `TCPServer` + 简易 HTTP 解析，或 Godot 子进程跑 Python）。
2. 游戏 **仍走 HTTP POST**，与连远程服务完全相同。
3. 本地服务内部调用现有 `AiDirector` 逻辑（经 JSON 适配层），保证行为与迁移前一致。

远程部署时：只改 `ai_service_url`，例如 `http://192.168.1.10:8765`，无需改游戏代码。

## 5. HTTP API

### 5.1 端点

| Method | Path | 说明 |
|--------|------|------|
| `POST` | `/v1/ai/tick` | 主决策接口：观测进，命令出 |
| `POST` | `/v1/ai/match/start` | 可选：通知新对局开始（AI 重置内部状态） |
| `POST` | `/v1/ai/match/end` | 可选：对局结束 |
| `GET` | `/health` | 健康检查 |

### 5.2 请求：`POST /v1/ai/tick`

**Headers：** `Content-Type: application/json`

```json
{
  "protocol_version": 1,
  "match_id": "m_20260904_001",
  "team": 0,
  "team_label": "Chinese",
  "tick": 128,
  "time_sec": 64.0,
  "profile_id": "chinese",
  "enemy_team": 1,

  "events": [
    {
      "seq": 40,
      "type": "resource_depleted",
      "entity_id": 30,
      "resource_type": "FOOD"
    }
  ],

  "observation": {
    "economy": {
      "food": 180,
      "wood": 200,
      "gold": 100,
      "pop_used": 4,
      "pop_cap": 5
    },
    "derived": {
      "own_tc_id": 5,
      "own_tc_pos": [-40.0, -40.0],
      "enemy_tc_id": 105,
      "enemy_tc_pos": [40.0, 40.0],
      "threat_near_base": false,
      "villager_count": 4,
      "military_count": 0,
      "incomplete_buildings": 0
    },
    "entities": [
      {
        "id": 12,
        "kind": "unit",
        "def_id": "villager",
        "team": 0,
        "pos": [-38.2, -39.1],
        "hp": 25.0,
        "max_hp": 25.0,
        "order": "GATHER",
        "gather_state": "to_drop_off",
        "carry_type": "FOOD",
        "carry_amount": 8.0,
        "target_id": 5,
        "last_resource_id": 30,
        "stuck_frames": 0
      },
      {
        "id": 5,
        "kind": "building",
        "def_id": "town_center",
        "team": 0,
        "pos": [-40.0, -40.0],
        "hp": 2400.0,
        "max_hp": 2400.0,
        "is_complete": true,
        "build_progress": 0.0,
        "train_queue_empty": true
      },
      {
        "id": 30,
        "kind": "resource",
        "resource_type": "FOOD",
        "pos": [-25.0, -20.0],
        "amount": 0.0
      }
    ]
  }
}
```

**字段说明：**

- `match_id`：一局对战唯一 ID，AI 服务按 `(match_id, team)` 维护状态。
- `events`：自上次 tick 以来的增量事件（可为空）；AI 应先 apply events 再读 `observation`（snapshot 为权威全量）。
- `observation.entities`：AI 可见的全部实体；Phase 1 可与现 AI 一样全图可见，Phase 2 由游戏按视野过滤后再发送。
- `team`：本请求替哪一方做决策；`ai_vs_ai` 每 tick 对双方各 POST 一次（或 AI 服务支持 batch，见 5.4）。

### 5.3 响应

**成功：`200 OK`**

```json
{
  "protocol_version": 1,
  "match_id": "m_20260904_001",
  "team": 0,
  "for_tick": 128,
  "commands": [
    {
      "command_id": "c_128_0",
      "op": "gather",
      "unit_id": 12,
      "target_id": 31
    },
    {
      "command_id": "c_128_1",
      "op": "train",
      "building_id": 5,
      "unit_def_id": "villager"
    }
  ],
  "debug": [
    { "category": "ECON", "message": "村民采集 wood" },
    { "category": "PHASE", "message": "ECO → BOOM" }
  ]
}
```

**错误：**

| HTTP | body | 游戏侧行为 |
|------|------|------------|
| `400` | `{ "error": "invalid_request", "detail": "..." }` | 记录日志；本 tick 不执行命令 |
| `408` / 超时 | — | 重试 1 次；仍失败则 skip tick |
| `500` | `{ "error": "internal" }` | 记录日志；skip tick |
| `503` | `{ "error": "busy" }` | 下一 tick 再试 |

### 5.4 可选：批量 tick（ai_vs_ai 优化）

`POST /v1/ai/tick_batch` 一次提交多方观测，减少 RTT：

```json
{
  "protocol_version": 1,
  "match_id": "m_001",
  "requests": [
    { "team": 0, "tick": 128, "observation": { "...": "..." }, "events": [] },
    { "team": 1, "tick": 128, "observation": { "...": "..." }, "events": [] }
  ]
}
```

响应为 `responses: [{ team, for_tick, commands, debug }, ...]`。

Phase 1 可先只做单方 `/v1/ai/tick`，ai_vs_ai 顺序调用两次。

## 6. 事件类型（Game → AI）

| type | 字段 | 说明 |
|------|------|------|
| `match_started` | `seed`, `teams[]`, `map_bounds` | 对局开始 |
| `entity_spawned` | `entity`（完整 entity 字典） | 单位/建筑/资源生成 |
| `entity_destroyed` | `entity_id`, `reason` | 死亡/拆除/采完 |
| `building_completed` | `entity_id` | 建造完成 |
| `resource_depleted` | `entity_id`, `resource_type` | 资源枯竭 |
| `unit_order_finished` | `entity_id`, `order` | 可选：命令自然结束 |
| `match_ended` | `winner_team` | 对局结束 |

事件由游戏在状态变化时写入 **EventBuffer**；每个 tick 结束时 flush 到 HTTP 请求。

## 7. 命令类型（AI → Game）

与现有 `UnitAgent` / `BuildingAgent` / `MatchState` 对齐：

| op | 参数 | 游戏执行 |
|----|------|----------|
| `move` | `unit_id`, `pos: [x,y]` | `command_move` |
| `stop` | `unit_id` | `command_stop` |
| `gather` | `unit_id`, `target_id`（resource） | `command_gather` |
| `build` | `unit_id`, `building_id` | `command_build` |
| `attack` | `unit_id`, `target_id` | `command_attack` |
| `place_building` | `building_def_id`, `pos`, `builder_id?` | `spend` + 放 foundation + 可选 `command_build` |
| `train` | `building_id`, `unit_def_id` | `enqueue_train` |
| `noop` | — | 无操作 |

**禁止 AI 直接做的（必须由游戏执行）：**

- `instantiate` 场景、`add_child`
- 修改 `sim_pos`、资源数、HP
- 调用 `MatchState.spend`（游戏在 `place_building` / `train` 校验通过后自行扣费）

## 8. 游戏侧模块设计

### 8.1 目录结构（新增）

```text
scripts/ai_gateway/
  ai_gateway.gd              # 对外入口：schedule_tick, on_match_start/end
  ai_config.gd               # 读取 GameSession / 环境变量
  entity_registry.gd         # entity_id ↔ Node2D
  observation_builder.gd     # 从 MatchState + Entities 构建 observation JSON
  event_buffer.gd            # 收集增量 events
  command_validator.gd     # 校验 AI 返回命令
  command_executor.gd        # 执行合法命令
  http_ai_client.gd          # HTTP POST，JSON 序列化
  local_ai_server.gd         # 内嵌 HTTP 服务（默认本地 AI）
  ai_service_adapter.gd      # JSON ↔ 现有 AiDirector 桥接（迁移期）

scripts/core/
  game_session.gd            # 扩展 ai_service_url 等配置
```

### 8.2 EntityRegistry

**职责：** 为每个仿真实体分配稳定整数 ID。

```gdscript
# 伪代码
func register(entity: Node2D) -> int
func unregister(entity_id: int) -> void
func resolve(entity_id: int) -> Node2D
func id_of(entity: Node2D) -> int
```

- 在 `unit_view` / `building_view` / `resource_node` `_ready` 时注册；`tree_exited` 时注销并发 `entity_destroyed` 事件。
- ID 写入 `entity.set_meta("entity_id", id)`。
- HTTP 协议中 **只出现 entity_id**，不出现节点路径。

### 8.3 ObservationBuilder

将现有 `AiBlackboard.refresh()` 逻辑 **迁到游戏侧**，输出纯 Dictionary（可 `JSON.stringify`）：

- 经济：`MatchState.get_resource` / 人口
- 实体：遍历 `Entities`，按 kind 序列化字段（对应 `unit_agent` 的 order、gather_state、carry 等）
- 派生：`derived` 块预计算（villager_count、threat_near_base 等）

**与旧 Blackboard 的关系：** AI 服务内不再扫 Godot 场景；若本地 embedded 服务仍用 GDScript Director，则 Director 改为读 **反序列化后的 ObservationStore**，而非 `Node2D`。

### 8.4 AiGateway

```gdscript
# 伪代码 — 挂载在 Match 根或 Bootstrap
func _on_ai_tick_boundary(tick: int, team: Enums.Team) -> void:
    var request := _build_tick_request(tick, team)
    var response := await _http_client.post_tick(request)
    if response == null:
        return
    for cmd in response.commands:
        if _validator.validate(cmd):
            _executor.execute(cmd)
        else:
            push_warning("AI command rejected: %s" % cmd)
    _emit_debug_lines(response.debug)
```

- 对 `match_2d`：每 0.5s 对 `Enums.Team.AI` 请求一次。
- 对 `ai_vs_ai`：对 `PLAYER` 与 `AI` 各请求一次（或 batch）。

### 8.5 CommandValidator 规则

| 命令 | 校验 |
|------|------|
| 所有 | entity 存在、未销毁、`team` 匹配 |
| `gather` | target 为 resource、`amount > 0` |
| `attack` | target 为敌对、存活 |
| `place_building` | `can_afford`、`can_place`、builder 为 idle 村民（若指定） |
| `train` | 建筑完成、队列空、`can_train` |

校验失败 **静默丢弃** 并写日志，不 crash。

### 8.6 CommandExecutor

| op | 实现 |
|----|------|
| `move/stop/gather/build/attack` | `EntityRegistry.resolve(unit_id).call("command_*", ...)` |
| `place_building` | 复用 `AiBuildManager.ensure_building` 逻辑，改为游戏侧函数 |
| `train` | `building.enqueue_train(load unit_def)` |

## 9. AI 服务实现（多语言）

### 9.1 协议约定

- **唯一依赖：** HTTP + JSON Schema（建议在 repo 增加 `docs/ai-service-schema/` 或 `protocol/ai_v1.json`）。
- **无 Godot 依赖：** Python / Go / Rust 均可实现。
- **状态：** AI 服务按 `(match_id, team)` 保存 phase、next_build_slot 等；每次 tick 也可仅依赖 observation（无状态模式，更易水平扩展）。

### 9.2 Python 服务骨架

```text
ai_service_python/
  main.py                 # FastAPI / Flask
  requirements.txt
  protocol/
    models.py               # Pydantic：TickRequest, TickResponse, Command
  brain/
    director.py             # 端口自 scripts/systems/ai/ai_director.gd
    economy_manager.py
    ...
  tests/
    test_tick_food_depleted.py
```

**FastAPI 示例：**

```python
# main.py（示意）
from fastapi import FastAPI
from protocol.models import TickRequest, TickResponse
from brain.director import AiDirector

app = FastAPI()
directors: dict[tuple[str, int], AiDirector] = {}

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/v1/ai/tick", response_model=TickResponse)
def tick(req: TickRequest) -> TickResponse:
    key = (req.match_id, req.team)
    director = directors.setdefault(key, AiDirector(req.profile_id))
    director.apply_events(req.events)
    director.apply_observation(req.observation)
    return director.evaluate(req.tick, req.match_id, req.team)
```

**迁移策略：** 将现有 GDScript Manager **逐文件翻译** 为 Python，单元测试对照 `ai_vs_ai` 决策日志。

### 9.3 本地 GDScript 内嵌服务（默认）

当未配置外部 URL 时，游戏启动 **LocalAiServer**：

```text
Option A（推荐）：子进程启动 python -m ai_service_python（若检测到 python/venv）
Option B：Godot 内 TCPServer 解析 HTTP，handler 调用 AiServiceAdapter
Option C：独立 godot --headless 跑 ai_service_gd 场景
```

**同一协议：** LocalAiServer 的 handler 收到 JSON 后，要么：

1. 调 Python 逻辑（若已部署）；或  
2. 调 `AiServiceAdapter`，内部 `JSON.parse` → 填充 `ObservationStore` → 跑现有 `AiDirector` → 输出 Command JSON。

这样 **本地默认路径与远程路径 JSON 完全一致**，便于 diff 与回归。

## 10. 时序与一致性

### 10.1 Tick 对齐

```text
Wall clock:  |---- 0.5s ----|---- 0.5s ----|
Game sim:    tick 127       tick 128
HTTP:              POST(obs 127) → cmds for 127
Execute:                    execute cmds @ start of tick 128
```

- **延迟 1 tick 执行**（推荐）：避免 AI 与同一帧仿真竞态。
- 请求带 `tick`；响应带 `for_tick`；Executor 仅在 `current_tick == for_tick + 1` 时执行（或队列缓存）。

### 10.2 幂等与重试

- 每条命令带 `command_id`；Executor 记录已执行 ID，重复 POST 不重复执行。
- 超时重试：同一 `tick` 最多重试 1 次，避免双倍命令。

### 10.3 异步 HTTP

- `AiGateway` 使用 `HTTPRequest` 异步请求；**不阻塞** `_physics_process`。
- 等待 AI 响应期间仿真继续；命令作用于下一 tick 边界。

## 11. 与现有场景集成

| 场景 | 变更 |
|------|------|
| `match_2d.tscn` | 移除/禁用进程内 `AiDirector` 节点；Match 根挂 `AiGateway` |
| `ai_vs_ai.tscn` | 两方均走 Gateway；决策日志来自 response.debug |
| `civ_select.tscn` | 增加 AI 服务 URL 配置项 |
| `match_bootstrap.gd` | `_setup_ai` → `_setup_ai_gateway()` + `match/start` |
| `ai_vs_ai_bootstrap.gd` | 同上；可选启动 embedded server |

**GameSession 示例：**

```gdscript
# civ_select 确认时
GameSession.ai_service_url = url_edit.text  # 空则默认 localhost
GameSession.ai_use_local_embedded = url_edit.text.is_empty()
```

## 12. 实现路线（P0–P6）总览

| 阶段 | 主题 | 前置 | 验收里程碑 |
|------|------|------|------------|
| **P0** | EntityRegistry + ObservationBuilder | — | snapshot JSON 与旧 Blackboard 一致 |
| **P1** | CommandValidator + CommandExecutor | P0 | mock 命令可驱动村民 gather |
| **P2** | HttpAiClient + AiGateway + LocalAiServer | P0, P1 | `ai_vs_ai` 走 HTTP 环路且行为不退化 |
| **P3** | 配置 UI（GameSession / civ_select） | P2 | 可切换本地 / 远程 URL |
| **P4** | Python FastAPI 最小服务 | P0 协议 | 游戏连 Python 完成采集改派 |
| **P5** | Manager 全量迁 Python | P4 | 进程内 Director 可删除 |
| **P6** | 视野 / batch / metrics / 生产化 | P5 | 远程部署 + 监控可用 |

**依赖关系：**

```text
P0 ──┬──► P1 ──► P2 ──► P3
     │              │
     └──────────────┼──► P4 ──► P5 ──► P6
```

**建议人力并行：**

- 轨道 A（游戏侧）：P0 → P1 → P2 → P3  
- 轨道 B（AI 服务侧）：P0 协议定稿后 → P4 → P5  
- P2 与 P4 在协议稳定后可并行联调  

---

## 12.1 P0 — EntityRegistry + ObservationBuilder

**目标：** 游戏侧能生成 **稳定 entity_id** 与 **可序列化 observation**，暂不改动现有 `AiDirector` 运行路径。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P0-1 | 定义协议常量与枚举字符串映射（`order` → `"GATHER"` 等） | `scripts/ai_gateway/ai_protocol.gd` | — |
| P0-2 | 实现 `EntityRegistry`（register / unregister / resolve / id_of） | `scripts/ai_gateway/entity_registry.gd` | P0-1 |
| P0-3 | 在 `unit_agent.gd` / `building_agent.gd` / `resource_node.gd` 的 `_ready` / `tree_exited` 挂钩 Registry | 修改现有 entity 脚本 | P0-2 |
| P0-4 | 实现 `EventBuffer`（push / drain / seq 自增） | `scripts/ai_gateway/event_buffer.gd` | P0-1 |
| P0-5 | 在 entity 生命周期与 `resource_node.extract` 枯竭时写入 events | 修改 entity + EventBuffer | P0-4 |
| P0-6 | 实现 `ObservationBuilder.build(match_state, entities, team, enemy_team, time_sec)` | `scripts/ai_gateway/observation_builder.gd` | P0-2 |
| P0-7 | 迁移 `AiBlackboard.refresh` 的计数与 derived 逻辑到 Builder | 同上 | P0-6 |
| P0-8 | 序列化 unit 字段：`order`, `gather_state`, `carry_*`, `stuck_frames`, `last_resource_id` | 同上 | P0-6 |
| P0-9 | 序列化 building 字段：`is_complete`, `build_progress`, `train_queue_empty` | 同上 | P0-6 |
| P0-10 | 序列化 resource 字段：`resource_type`, `amount`, `pos` | 同上 | P0-6 |
| P0-11 | 编写 JSON Schema / 示例 golden 文件 | `protocol/ai_v1.schema.json`, `protocol/examples/tick_request.json` | P0-6 |
| P0-12 | 单元测试：Builder 输出 vs 旧 Blackboard 同场景数值一致 | `tests/test_observation_builder.gd` | P0-7 |
| P0-13 | 单元测试：Registry 注册/注销/resolve 与 meta 持久化 | `tests/test_entity_registry.gd` | P0-3 |

### 交付物

- `scripts/ai_gateway/` 下 P0 模块（不含 HTTP）  
- `protocol/ai_v1.schema.json`  
- 2 个 GUT 测试全绿  

### 验收标准

- [x] 任意 `ai_vs_ai` 开局 1 帧内，`ObservationBuilder` 输出可 `JSON.stringify` 无循环引用
- [x] `derived.villager_count` / `economy.food` 与直接读 `MatchState` + 扫节点一致
- [x] entity 销毁后 `resolve(id)` 返回 `null`，且 `EventBuffer` 含 `entity_destroyed`
- [x] golden request 文件 `protocol/examples/tick_request.json` 与 schema 结构一致

### 不在本阶段

- HTTP、命令执行、UI 配置  
- 修改 `AiDirector` 调用链  

---

## 12.2 P1 — CommandValidator + CommandExecutor

**目标：** 游戏侧能 **校验并执行** AI 返回的命令 JSON，先用内存 mock 响应，不走 HTTP。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P1-1 | 定义命令 Dictionary 结构与 `op` 枚举 | `scripts/ai_gateway/ai_protocol.gd`（扩展） | P0-1 |
| P1-2 | 实现 `CommandValidator.validate(cmd, ctx)` 返回 `{ok, reason}` | `scripts/ai_gateway/command_validator.gd` | P0-2, P1-1 |
| P1-3 | 校验：entity 存在、team 归属、HP > 0 | 同上 | P1-2 |
| P1-4 | 校验：`gather` → target 为 resource 且 amount > 0 | 同上 | P1-2 |
| P1-5 | 校验：`attack` → 敌对且存活 | 同上 | P1-2 |
| P1-6 | 校验：`place_building` → can_afford + BuildSystem.can_place | 同上 | P1-2 |
| P1-7 | 校验：`train` → 建筑完成、队列空、can_train | 同上 | P1-2 |
| P1-8 | 实现 `CommandExecutor.execute(cmd, ctx)` | `scripts/ai_gateway/command_executor.gd` | P1-2 |
| P1-9 | 执行：`move/stop/gather/build/attack` → `command_*` | 同上 | P1-8 |
| P1-10 | 执行：`place_building` → spend + instantiate foundation + 可选 command_build（从 `AiBuildManager` 抽取 `place_foundation` 到游戏侧） | `scripts/ai_gateway/build_placement.gd` | P1-8 |
| P1-11 | 执行：`train` → `enqueue_train` | `command_executor.gd` | P1-8 |
| P1-12 | 命令幂等：`command_id` 去重表（本局有效） | `command_executor.gd` | P1-8 |
| P1-13 | 测试：mock `{op:gather}` 驱动 idle 村民 | `tests/test_command_executor.gd` | P1-11 |
| P1-14 | 测试：非法 team / 不存在 id 被拒绝 | `tests/test_command_validator.gd` | P1-7 |
| P1-15 | 测试：`place_building` 资源不足时 reject | 同上 | P1-6 |

### 交付物

- `command_validator.gd`, `command_executor.gd`, `build_placement.gd`  
- 2 个 GUT 测试  

### 验收标准

- [x] 对 idle 村民注入 `gather` 命令后，下一帧 `order == GATHER`  
- [x] 对敌对单位注入 `attack` 后 `order == ATTACK`  
- [x] 重复 `command_id` 不重复执行  
- [x] 所有 reject 写 `push_warning` 或结构化日志，不 crash  

### 不在本阶段

- HTTP 客户端、AiGateway 调度  
- AI 服务进程  

---

## 12.3 P2 — HttpAiClient + AiGateway + LocalAiServer

**目标：** 完整 HTTP 环路；默认内嵌本地服务；`ai_vs_ai` 决策改走 Gateway，行为与迁移前 **大致一致**。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P2-1 | 实现 `AiConfig.from_game_session()` 读取 URL / timeout | `scripts/ai_gateway/ai_config.gd` | — |
| P2-2 | 实现 `HttpAiClient.post_tick(request_dict) -> Dictionary`（HTTPRequest 异步） | `scripts/ai_gateway/http_ai_client.gd` | P2-1 |
| P2-3 | 请求/响应 JSON 序列化、错误码映射（400/408/500） | 同上 | P2-2 |
| P2-4 | 超时重试 1 次；失败 skip tick 并打日志 | 同上 | P2-3 |
| P2-5 | 实现 `AiGateway`：tick 调度、组装 request、调用 client、validator、executor | `scripts/ai_gateway/ai_gateway.gd` | P0-6, P1-11, P2-2 |
| P2-6 | 延迟 1 tick 执行：响应 `for_tick` 入队，下一边界 dequeue | `ai_gateway.gd` | P2-5 |
| P2-7 | `match/start` / `match/end` 生命周期钩子 | `ai_gateway.gd` | P2-5 |
| P2-8 | 实现 `AiServiceAdapter`：JSON observation → 填充 ObservationStore → 调现有 `AiDirector` → 输出 commands JSON | `scripts/ai_gateway/ai_service_adapter.gd` | P0-6 |
| P2-9 | 实现 `ObservationStore`（纯 Dictionary，供 Adapter 内 Director 读） | `scripts/ai_gateway/observation_store.gd` | P2-8 |
| P2-10 | 改造 `AiDirector` / Managers：增加 **数据模式** 分支（读 ObservationStore 而非 Node2D）；或通过 Adapter 临时构造伪 blackboard | 修改 `scripts/systems/ai/*` | P2-8 |
| P2-11 | 实现 `LocalAiServer`：TCPServer + 简易 HTTP 解析，路由 `/v1/ai/tick` → Adapter | `scripts/ai_gateway/local_ai_server.gd` | P2-8 |
| P2-12 | 实现 `GET /health` | `local_ai_server.gd` | P2-11 |
| P2-13 | `match_bootstrap.gd`：启动 Gateway + 按需启动 LocalAiServer | 修改 bootstrap | P2-5, P2-11 |
| P2-14 | `ai_vs_ai_bootstrap.gd`：两方 team 各 tick；debug 来自 response.debug | 修改 bootstrap | P2-5 |
| P2-15 | 禁用场景内 `ChineseAi` / `TeutonsAi` 进程内 Director 节点（或改为 Gateway 驱动） | 修改 scene/bootstrap | P2-14 |
| P2-16 | 集成测试：LocalAiServer + Gateway 跑 30s ai_vs_ai | `tests/test_ai_gateway_integration.gd` | P2-15 |
| P2-17 | 对照：迁移前后 decision log 关键事件（PHASE / ECON / BUILD）一致率 > 90% | 手动 / 脚本 | P2-16 |

### 交付物

- 完整 `scripts/ai_gateway/`（含 HTTP + LocalServer + Adapter）  
- `match_bootstrap` / `ai_vs_ai_bootstrap` 接入  
- 集成测试 1 个  

### 验收标准

- [x] 不配置外部 URL 时，游戏自动起 `127.0.0.1:8765` 且 `/health` 返回 200  
- [x] 游戏进程内 **无直接** `unit.call("command_*")` 来自旧 Director（全经 Executor）  
- [x] `ai_vs_ai` 30s 内双方村民有持续 gather / train 日志  
- [x] HTTP 请求体与 `protocol/examples/tick_request.json` 结构一致  

### 不在本阶段

- civ_select UI  
- Python 服务  
- 删除 GDScript Director（Adapter 仍依赖）  

---

## 12.4 P3 — 配置 UI

**目标：** 开局可配置 AI 服务地址；支持本地默认 / 远程 / 仅本地 embedded 开关。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P3-1 | 扩展 `GameSession`：`ai_service_url`, `timeout`, `use_local_embedded`, `protocol_version` | `scripts/core/game_session.gd` | — |
| P3-2 | 启动时读环境变量 `AOE2_AI_URL` 覆盖（可选） | `scripts/ai_gateway/ai_config.gd` | P3-1 |
| P3-3 | `civ_select.tscn` 增加「AI 服务地址」LineEdit + 「使用内嵌本地服务」CheckBox | 修改 scene | P3-1 |
| P3-4 | 确认按钮写入 `GameSession`；空 URL → 默认 localhost + embedded | 修改 civ_select 脚本 | P3-3 |
| P3-5 | Gateway 启动前 `GET /health` 探活；失败提示并 fallback embedded 或禁用 AI | `ai_gateway.gd` | P2-5 |
| P3-6 | 对局内 Debug 面板显示当前 AI URL、最近 tick 延迟 ms | 可选 HUD 标签 | P2-5 |
| P3-7 | 文档：配置说明写入 `docs/ai_vs_ai_arena.md` | 文档 | P3-4 |

### 交付物

- 可配置的文明选择界面  
- GameSession 字段  
- 探活与 fallback 逻辑  

### 验收标准

- [x] UI 填 `http://127.0.0.1:9999` 且服务不存在时，有明确错误提示  
- [x] UI 留空时自动 embedded + 默认端口  
- [x] 填远程 mock URL（如 Postman mock）可收到请求  

### 不在本阶段

- Python 服务本体  
- 鉴权 Token  

---

## 12.5 P4 — Python FastAPI 最小服务

**目标：** 独立 Python 进程实现 `/v1/ai/tick`；游戏可连 Python 完成 **基本经济循环**（采浆果 → 改派木头）。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P4-1 | 初始化 `ai_service_python/` 项目结构 | 见 §9.2 | P0-11 协议 |
| P4-2 | Pydantic 模型：`TickRequest`, `TickResponse`, `Command`, `Observation` | `protocol/models.py` | P4-1 |
| P4-3 | FastAPI 路由：`GET /health`, `POST /v1/ai/tick` | `main.py` | P4-2 |
| P4-4 | `POST /v1/ai/match/start`, `POST /v1/ai/match/end`（重置 director 状态） | `main.py` | P4-3 |
| P4-5 | 端口 `ObservationStore` + `EventStore`（Python 版） | `brain/stores.py` | P4-2 |
| P4-6 | 移植 `AiEconomyManager` 核心：`assign_gatherers` + `_pick_gather_target` | `brain/economy_manager.py` | P4-5 |
| P4-7 | 移植阶段机 `_update_phase`（ECO / BOOM / ATTACK 简化版） | `brain/director.py` | P4-5 |
| P4-8 | 输出 commands JSON + debug 日志 | `brain/command_builder.py` | P4-6 |
| P4-9 | pytest：固定 observation → 预期 gather wood（浆果 amount=0） | `tests/test_economy_food_depleted.py` | P4-6 |
| P4-10 | `requirements.txt`（fastapi, uvicorn, pydantic） | 根目录 | P4-1 |
| P4-11 | README：启动命令 `uvicorn main:app --port 8765` | `ai_service_python/README.md` | P4-3 |
| P4-12 | 游戏联调：GameSession URL 指向 Python；跑 ai_vs_ai 验证改派 | 手动 | P2-5, P4-3 |

### 交付物

- 可运行的 Python AI 服务（经济 + 阶段机最小集）  
- pytest ≥ 3 个用例  
- README  

### 验收标准

- [x] `curl /health` 返回 `{"status":"ok"}`  
- [x] 固定 golden observation POST 后返回非空 `commands`  
- [x] 游戏连 Python 时，浆果采完后 10s 内出现 `gather` 木头命令（debug 可见）— 见 `ai_service_python/README.md` 联调步骤  
- [x] 不依赖 Godot 运行时  

### 不在本阶段

- Build / Production / Army / Combat 全量移植  
- Docker 镜像（可 P6）  

---

## 12.6 P5 — Manager 全量迁 Python

**目标：** Python 服务覆盖现有 GDScript Managers；游戏侧删除进程内决策，LocalAiServer 默认 **拉起 Python 子进程** 或要求外部 URL。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P5-1 | 移植 `AiBuildManager` → `place_building` 命令生成（不 instantiate） | `brain/build_manager.py` | P4-7 |
| P5-2 | 移植 `AiProductionManager` → `train` 命令 | `brain/production_manager.py` | P4-7 |
| P5-3 | 移植 `AiArmyManager` → `move` 集结 | `brain/army_manager.py` | P4-7 |
| P5-4 | 移植 `AiCombatManager` → `attack` | `brain/combat_manager.py` | P4-7 |
| P5-5 | 加载 `CivAiProfile`：Python 读 JSON 导出或手写 yaml（从 `data/ai/*.tres` 导出脚本） | `brain/profile_loader.py`, `data/ai/*.json` | P5-1 |
| P5-6 | Director 完整 `evaluate()` 调度顺序与 GDScript 一致 | `brain/director.py` | P5-1~5 |
| P5-7 | golden test：同一 observation，GDScript Adapter vs Python 输出 commands diff | `tests/test_parity_gdscript_python.py` | P5-6 |
| P5-8 | LocalAiServer 改为：优先 `OS.execute` 启动 Python；无 Python 时 fallback GDScript Adapter | `local_ai_server.gd` | P4-3 |
| P5-9 | 标记 `scripts/systems/ai/` 为 deprecated；场景移除 `AiDirector` 节点 | 修改 scene/bootstrap | P5-7 |
| P5-10 | CI job：pytest + headless Godot 集成（可选） | `.github/workflows/ai-service.yml` | P5-7 |

### 交付物

- Python `brain/` 全 Manager  
- GDScript ↔ Python parity 测试  
- 进程内 Director 退出主路径  

### 验收标准

- [ ] `ai_vs_ai` 完整 3 分钟对局可结束（有 ATTACK / 伤亡）  
- [ ] parity 测试：≥ 80% tick 的 commands 与 Adapter 一致（允许顺序差异）  
- [ ] 仓库内无 `AiDirector._process` 在正式对局路径运行  

### 不在本阶段

- 视野 fog、DEFEND 精细逻辑  
- `/tick_batch`  

---

## 12.7 P6 — 生产化（视野 / batch / metrics）

**目标：** 远程部署可用；性能与可观测性达标；协议 v1 冻结。

### 任务清单

| ID | 任务 | 产出文件 | 依赖 |
|----|------|----------|------|
| P6-1 | 游戏侧按 VisionService 过滤 observation.entities（AI 不全图作弊） | `observation_builder.gd` | P5-9 |
| P6-2 | Python DEFEND 阶段 + `threat_near_base` 行为 | `brain/director.py` | P5-6 |
| P6-3 | 实现 `POST /v1/ai/tick_batch`（ai_vs_ai 单次 RTT） | Python + Gateway | P5-6 |
| P6-4 | Gateway metrics：tick 延迟直方图、reject 计数、timeout 计数 | `ai_gateway_metrics.gd` | P2-5 |
| P6-5 | Python 结构化日志（match_id, team, phase, cmd_count） | `main.py` | P5-6 |
| P6-6 | 可选 Bearer Token 鉴权 | Gateway + FastAPI middleware | P3-1 |
| P6-7 | Dockerfile + docker-compose（game 不容器化，仅 AI 服务） | `ai_service_python/Dockerfile` | P5-6 |
| P6-8 | 协议冻结：`protocol_version: 1` 变更日志 | `protocol/CHANGELOG.md` | 全部 |
| P6-9 | 负载测试：ai_vs_ai 双方向 Python 5 分钟无 timeout | 脚本 | P6-3 |

### 交付物

- batch API、metrics、Docker  
- 视野-limited observation  
- 协议 CHANGELOG  

### 验收标准

- [ ] Docker 启动 AI 服务后，游戏仅改 URL 即可连入  
- [ ] ai_vs_ai 平均 tick RTT < 100ms（本地 LAN）  
- [ ] 协议 v1 文档与 schema 一致且标注 frozen  

---

## 12.8 跨阶段检查清单（Definition of Done）

每阶段合并前需满足：

1. **测试：** 本阶段列出的 GUT / pytest 全绿  
2. **文档：** 本阶段 API 或配置变更已更新 `docs/ai-service-design.md` / README  
3. **回归：** `ai_vs_ai` 可启动且无 script error  
4. **协议：** 若改 JSON 字段，同步 `protocol/ai_v1.schema.json` + golden 示例  
5. **Review：** 游戏侧无新增 `AiDirector` 对 Node 的直接命令（P2 起）  

---

## 12.9 文件树（完整交付态）

```text
scripts/ai_gateway/
  ai_protocol.gd
  ai_config.gd
  entity_registry.gd
  event_buffer.gd
  observation_builder.gd
  observation_store.gd          # P2 Adapter 用
  command_validator.gd
  command_executor.gd
  build_placement.gd
  http_ai_client.gd
  ai_gateway.gd
  local_ai_server.gd
  ai_service_adapter.gd         # P2–P4；P5 后仅 fallback
  ai_gateway_metrics.gd         # P6

protocol/
  ai_v1.schema.json
  CHANGELOG.md                  # P6
  examples/
    tick_request.json
    tick_response.json

ai_service_python/
  main.py
  requirements.txt
  README.md
  Dockerfile                    # P6
  protocol/models.py
  brain/
    stores.py
    director.py
    economy_manager.py
    build_manager.py
    production_manager.py
    army_manager.py
    combat_manager.py
    command_builder.py
    profile_loader.py
  tests/
    test_economy_food_depleted.py
    test_parity_gdscript_python.py

tests/                          # Godot GUT
  test_entity_registry.gd
  test_observation_builder.gd
  test_command_validator.gd
  test_command_executor.gd
  test_ai_gateway_integration.gd
```

---

## 12.10 工时估算（参考）

| 阶段 | 预估（人日） | 说明 |
|------|-------------|------|
| P0 | 2–3 | Registry + Builder + 测试 |
| P1 | 2–3 | Validator + Executor + place_building 抽取 |
| P2 | 4–6 | HTTP + LocalServer + Director 数据模式适配 |
| P3 | 1 | UI + GameSession |
| P4 | 3–4 | Python 骨架 + Economy |
| P5 | 5–8 | 全 Manager 移植 + parity |
| P6 | 3–5 | batch / 视野 / Docker / metrics |
| **合计** | **20–30** | 双轨道并行可压缩日历时间 |

---

## 13. 测试策略

| 层级 | 方法 |
|------|------|
| 协议 | JSON Schema 校验；golden file 对比 request/response |
| 游戏 | `test_ai_gateway.gd`：mock HTTP server 返回固定 commands |
| AI 服务 | Python pytest：`TickRequest` → 预期 `commands` |
| 集成 | headless 跑 `ai_vs_ai` N 秒，对比 decision log hash |
| 本地/远程等价 | 同一 observation 分别 POST 本地 embedded 与 Python，diff commands |

## 14. 安全与运维

- **仅 localhost 默认监听**；远程需显式配置 URL。
- 生产可加 `Authorization: Bearer <token>`（Phase 2）。
- `/health` 供 Docker / k8s 探活。
- 日志：游戏侧记录 `match_id, tick, latency_ms, commands_count`；AI 侧记录 `profile_id, phase`。

**Docker 示例（Python AI）：**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY ai_service_python/ .
RUN pip install -r requirements.txt
EXPOSE 8765
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8765"]
```

## 15. 风险与缓解

| 风险 | 缓解 |
|------|------|
| HTTP 延迟导致 tick 漂移 | 异步请求 + 延迟 1 tick 执行；超时 skip |
| AI 返回非法 ID | CommandValidator 必过 Registry |
| 本地/远程行为不一致 | 同一 JSON golden test；Python 移植对照 GDScript |
| 双端 state 分叉 | observation 为权威全量；events 仅辅助 |
| ai_vs_ai 双倍 HTTP | 后续 `/tick_batch` |

## 16. 附录：与进程内 AI 模块映射

| 现有（游戏内） | 分离后 |
|----------------|--------|
| `AiDirector.evaluate()` | AI 服务 `POST /v1/ai/tick` handler |
| `AiBlackboard.refresh()` | 游戏 `ObservationBuilder` |
| `AiEconomyManager` 等 | AI 服务内（Python/GDScript） |
| `unit.call("command_*")` | 游戏 `CommandExecutor` |
| `AiBuildManager` instantiate | 游戏 `place_building` 执行 |
| `AiDecisionLog` | response.debug → UI / 控制台 |

---

## 17. 下一步（建议执行顺序）

按 **§12.1 P0-1** 起逐项推进；每完成一阶段勾选 **§12.8 DoD**。

| 顺序 | 任务 ID | 说明 |
|------|---------|------|
| 1 | P0-1 ~ P0-13 | Registry + ObservationBuilder + schema + GUT |
| 2 | P1-1 ~ P1-15 | Validator + Executor + mock 命令测试 |
| 3 | P2-1 ~ P2-17 | HTTP 环路 + LocalServer + ai_vs_ai 接入 |
| 4 | P3-1 ~ P3-7 | civ_select 配置 UI |
| 5 | P4-1 ~ P4-12 | Python FastAPI 最小经济 AI |
| 6 | P5-1 ~ P5-10 | Manager 全量 Python + parity |
| 7 | P6-1 ~ P6-9 | 视野 / batch / Docker / metrics |

**参考实现（当前进程内）：** `scripts/systems/ai/`、`docs/superpowers/specs/2026-08-14-ai-system-design.md`
