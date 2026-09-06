# 大模型风格 AI Agent 交互设计

**Date:** 2026-09-04  
**Status:** 实施完成（P0–P3）；任务表见 [llm-agent-ai-tasks.md](llm-agent-ai-tasks.md)  
**Related:** [AI 服务分离设计](ai-service-design.md)、协议 v1 `protocol/ai_v1.schema.json`、配置 `data/game_settings.cfg`

## 1. 目标

将当前「游戏 → HTTP tick → AI 服务 → 命令批次」升级为更接近 **大模型 Agent** 的交互形态：

| 角色 | 类比 | 职责 |
|------|------|------|
| **游戏（Godot）** | Agent / Tool Runtime | 维护仿真；组装 prompt 上下文；校验并执行工具调用；不信任未校验的命令 |
| **AI 服务** | 大模型（或兼容层） | 接收 messages；返回非流式 completion；可内嵌规则脑或真实 LLM |

**硬性约束：**

1. **非流式**：一次请求一次完整响应（`stream: false`）。
2. **可配置 API Token**：Bearer（或等价）鉴权，配置文件 / 环境变量可覆盖。
3. **游戏侧仍为唯一权威**：AI 只建议动作；落地前必须经 `CommandValidator`。
4. **兼容路径**：保留现有 v1 tick 协议；新协议作为 v2（或 `openai`-compatible 适配层），可切换。

## 2. 动机与现状差距

### 2.1 现状（v1）

```text
AiGateway  --POST /v1/ai/tick_batch-->  AI Service
            observation + events              commands[]
```

- 载荷是领域专用 JSON（`observation` / `commands`），不是 messages。
- 服务端日志只打摘要，看起来「没有 blackboard」；实际上上下文在 `observation` 里，blackboard 由服务端重建。
- Python 服务目前是 **规则 AI**，不是大模型，但接口已是无状态 HTTP。

### 2.2 目标形态

```text
游戏 Agent
  ├─ System：规则、可用工具、输出 schema
  ├─ User：本 tick 观测 / 事件 / 简要历史
  └─ POST /v1/chat/completions  (或兼容 OpenAI Chat Completions)
        │
        ▼
AI 服务（模仿 LLM）
  └─ choices[0].message：自然语言可选 + tool_calls / 结构化 commands
        │
        ▼
游戏解析 → Validator → Executor
```

这样后续可无缝换成真实 OpenAI / 本地 vLLM / 自研模型，而规则脑只需「伪装」成同一响应格式。

## 3. 总体架构

```text
┌──────────────────────────────────────────────────────────────┐
│                     游戏进程 (Godot Agent)                     │
│  ObservationBuilder → PromptAssembler → LlmGateway           │
│         │                                    │                 │
│         │                         Authorization: Bearer <token>│
│         ▼                                    ▼                 │
│  Tool/Command catalog              HTTP JSON (non-stream)      │
│  CommandValidator ←── parse completion ──┘                    │
│  CommandExecutor → Simulation                                 │
└───────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────┐
│              AI 服务（LLM 兼容 / 规则脑适配器）                 │
│  ChatCompletionsHandler                                       │
│    ├─ 若 backend=rules：Observation → AiDirector → tool_calls │
│    └─ 若 backend=llm：转发真实模型（可选第二阶段）              │
└──────────────────────────────────────────────────────────────┘
```

**每个 AI tick（建议仍 0.5s，可配置）：**

1. 仿真推进，积攒 events。  
2. 构建 `observation`（与 v1 相同数据源）。  
3. `PromptAssembler` 生成 `messages[]` + `tools[]`。  
4. `POST .../chat/completions`，`stream: false`。  
5. 解析 `tool_calls`（或 content 中的 JSON commands）→ 现有 `Command` 结构。  
6. Validator / Executor 落地；可选把执行结果作为下一轮 `tool` role 消息（多轮可二期）。

**首期范围：** 单轮（每 tick 独立 messages，不强制多轮对话历史）。  
**二期可选：** 短窗口对话历史、tool result 回传、失败重试。

## 4. 消息与工具协议（建议 v2）

### 4.1 请求（游戏 → AI）

对齐常见 Chat Completions 形状（字段可裁剪）：

```json
{
  "model": "aoe2-rules-v1",
  "stream": false,
  "temperature": 0,
  "max_tokens": 2048,
  "messages": [
    {
      "role": "system",
      "content": "<规则 + 输出约束 + 文明/阶段提示>"
    },
    {
      "role": "user",
      "content": "<本 tick 文本化观测 + 可选 JSON 附件说明>"
    }
  ],
  "tools": [ { "type": "function", "function": { "name": "gather", "...": "..." } } ],
  "tool_choice": "auto",
  "metadata": {
    "protocol_version": 2,
    "match_id": "m_...",
    "team": 0,
    "tick": 128,
    "time_sec": 64.0,
    "profile_id": "chinese"
  },
  "observation": { }
}
```

说明：

- **`messages`**：大模型主通道；`user` 内容由观测渲染（可读文本），便于真 LLM。  
- **`observation`（可选并列）**：保留 v1 结构化快照，方便规则脑零解析损耗；真 LLM 可忽略，只读 text。  
- **`tools`**：与现有 command ops 对齐（`gather` / `train` / `place_building` / `move` / `attack` / `build` / `stop` / `noop`）。  
- **`metadata`**：match/tick/team，便于日志与幂等。  
- **`stream` 必须为 `false`**；服务若收到 `true` 应 `400`。

### 4.2 System 提示（摘要）

由游戏或服务模板生成，包含：

- 你是 RTS 指挥官，只能通过 tools 行动。  
- 坐标与 entity id 以 observation 为准；不可编造 id。  
- 每 tick 可返回 0..N 个 tool_calls；不要输出无关长文。  
- 人口/资源不足时不要 train / place。

### 4.3 User 提示（观测渲染）

建议固定模板，例如：

```text
Match tick=128 time=64.0s team=Chinese phase_hint=ECO
Economy: food=180 wood=200 gold=100 pop=4/5
Base TC id=5 at (-40,-40); Enemy TC id=105 at (40,40)
Villagers: 4 idle/gathering...
Visible resources: ...
Events since last tick: resource_depleted#30
```

结构化细节仍可附在同请求的 `observation` 字段，避免纯文本丢精度。

### 4.4 响应（AI → 游戏）

非流式 completion：

```json
{
  "id": "chatcmpl_...",
  "object": "chat.completion",
  "model": "aoe2-rules-v1",
  "choices": [
    {
      "index": 0,
      "finish_reason": "tool_calls",
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": {
              "name": "gather",
              "arguments": "{\"unit_id\":12,\"target_id\":30}"
            }
          }
        ]
      }
    }
  ],
  "usage": { "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0 }
}
```

**规则脑适配器：** 内部仍跑现有 `AiDirector`，把 `commands[]` 映射为 `tool_calls`，`usage` 可填 0 或启发式估计。

**兼容回落：** 若无 `tool_calls`，允许 `message.content` 为 JSON：

```json
{ "commands": [ { "op": "gather", "unit_id": 12, "target_id": 30, "command_id": "c_128_1" } ] }
```

游戏解析优先级：`tool_calls` > `content` JSON commands > 空（noop）。

### 4.5 工具参数与 v1 Command 映射

| tool name | 主要参数 | v1 `op` |
|-----------|----------|---------|
| `gather` | `unit_id`, `target_id` | `gather` |
| `train` | `building_id`, `unit_def_id` | `train` |
| `place_building` | `builder_id?`, `building_def_id`, `pos` | `place_building` |
| `build` | `unit_id`, `building_id` | `build` |
| `move` | `unit_id`, `pos` | `move` |
| `attack` | `unit_id`, `target_id` | `attack` |
| `stop` | `unit_id` | `stop` |
| `noop` | — | `noop` |

`command_id`：可由游戏在解析后生成（`c_{tick}_{seq}`），或要求模型在 arguments 中带上；重复 id 仍由 `CommandExecutionContext` 去重。

## 5. 鉴权与可配置 Token

### 5.1 传输

```http
POST /v1/chat/completions HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

- Token 为空：仅允许本机 loopback（可选强制）；或开发模式跳过校验。  
- Token 非空：服务端与客户端必须一致，否则 `401`。

与现有 `AOE2_AI_TOKEN` / `GameSession.ai_service_token` 对齐。

### 5.2 配置（建议写入 `game_settings.cfg`）

```ini
[game]
speed=1.0

[ai]
; URLs 必须加引号，否则 Godot ConfigFile 会解析失败
chat_url="http://127.0.0.1:8765/v1/chat/completions"
service_url="http://127.0.0.1:8765"
api_token=""
; openai | rules_compat
backend="rules_compat"
model="aoe2-rules-v1"
timeout_sec=2.0
tick_interval_sec=0.5
; v1_tick | v2_chat
protocol="v2_chat"
use_local_embedded=true
max_tokens=2048
```

加载顺序建议：

1. `user://game_settings.cfg`（若存在）  
2. `res://data/game_settings.cfg`  
3. 环境变量覆盖：`AOE2_AI_URL`、`AOE2_AI_TOKEN`  
4. 文明选择 UI 写入 `GameSession`（运行时覆盖）

`GameSettings` / `AiConfig` 扩展对应字段；启动时 `apply_from_config()` 一并加载 AI 段。

## 6. 游戏侧模块变更

| 模块 | 变更 |
|------|------|
| `PromptAssembler`（新） | observation + events → `messages` / `tools` |
| `LlmResponseParser`（新） | completion → `commands[]` |
| `AiGateway` | 按 `protocol` 走 v1 tick 或 v2 chat；统一后续 Validator |
| `HttpAiClient` | 支持 Bearer；`post_chat_completions` |
| `GameSettings` / `AiConfig` | token、chat_url、protocol、model、max_tokens |
| `CommandValidator` | 不变（权威校验） |

**双队 batch：** v2 可提供 `/v1/chat/completions_batch`（requests[]），或游戏串行两次 chat；首期允许串行，降低协议复杂度。

## 7. AI 服务侧模块变更

| 模块 | 变更 |
|------|------|
| `POST /v1/chat/completions` | 非流式；校验 token；拒绝 stream |
| `RulesCompatBackend` | 从 messages/metadata/observation 还原 → 现有 Director → tool_calls |
| `LlmProxyBackend`（可选） | 转发真实模型，透传 tools |
| 日志 | 除摘要外，debug 档可记录 messages 长度 / tool_call 名（避免默认打满 observation） |

规则脑路径伪代码：

```text
obs = request.observation or parse_from_user_text(request.messages)
director.evaluate(tick, obs) -> commands
return chat.completion { tool_calls = map(commands) }
```

## 8. 与 v1 的关系

| | v1 tick | v2 chat |
|--|---------|---------|
| 路径 | `/v1/ai/tick`, `/tick_batch` | `/v1/chat/completions` |
| 上下文 | `observation` | `messages` + 可选 `observation` |
| 输出 | `commands[]` | `tool_calls` / JSON content |
| 鉴权 | 已有 Bearer | 同左，配置项统一 |
| 状态 | **保持**，默认生产可用 | **新增**，配置切换 |

迁移策略：

1. 实现 RulesCompat，行为对齐现有 pytest / parity。  
2. `protocol=v2_chat` 在 `ai_vs_ai` 联调。  
3. 真 LLM 作为可选 backend，不阻塞规则路径。

## 9. 错误与超时

| 情况 | 游戏行为 |
|------|----------|
| 超时 / 5xx | 本 tick noop；metrics 记 skip；可重试 1 次 |
| 401 | 停止 AI 或回退 embedded（若允许） |
| 非法 JSON / 无 choices | noop |
| tool 参数缺字段 / 未知 id | Validator 拒绝该条，其余可执行 |
| 超长响应 | 截断解析失败则 noop |

不因单次失败暂停仿真。

## 10. 安全

1. Token 不进仓库；`user://` 与环境变量优先。  
2. 导出包内 `res://` 默认 token 留空。  
3. 模型不可直接改资源/人口；只能经 tools。  
4. 日志默认不打印完整 Bearer 与超大 observation（可 debug 开关）。

## 11. 测试计划

1. **契约：** 固定 observation → RulesCompat → 期望 tool_calls（对齐 `opening_eco` fixture）。  
2. **解析：** 多种 completion 变体（tool_calls / content JSON / 空）。  
3. **鉴权：** 有无 token、错误 token。  
4. **网关：** `protocol=v1_tick` 与 `v2_chat` 切换，仿真行为接近。  
5. **非流式：** 请求 `stream:true` 被拒。

## 12. 实施分期

任务级拆解与验收标准见 **[llm-agent-ai-tasks.md](llm-agent-ai-tasks.md)**。

| 阶段 | 内容 |
|------|------|
| **P0** | 设计冻结；cfg `[ai]` 字段；Token 配置打通 |
| **P1** | `/v1/chat/completions` + RulesCompat；Godot PromptAssembler + Parser |
| **P2** | AiGateway 配置切换 v1/v2；ai_vs_ai 联调；parity 测试 |
| **P3** |（可选）真 LLM backend；短历史；batch chat |

## 13. 非目标（首期不做）

- 流式 SSE / WebSocket  
- 模型在服务端直接改 Godot 场景树  
- 完整多轮 ReAct 循环（tool result 多轮）  
- 语音 / 多模态截图输入  

## 14. 决策摘要

1. 游戏是 Agent，AI 服务模仿大模型 Chat Completions（**非流式**）。  
2. 上下文以 **messages + 可选 observation** 下发；blackboard 仍只存在于服务端内部。  
3. 动作以 **tool_calls** 为主，兼容 content JSON commands。  
4. **Token 可配置**（cfg / 环境变量 / UI → GameSession）。  
5. v1 tick 保留；v2 可切换，规则脑先伪装成 LLM 响应。
