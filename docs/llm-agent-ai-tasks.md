# LLM Agent AI 交互 — 任务拆解

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax.  
> **Spec:** [docs/llm-agent-ai-design.md](../llm-agent-ai-design.md)  
> **Related:** [docs/ai-service-design.md](../ai-service-design.md)、`protocol/ai_v1.schema.json`

**Goal:** 游戏以 Agent 方式调用 AI 服务的 Chat Completions（非流式）；规则脑先伪装成 LLM；Token / 协议可配置；v1 tick 保留可切换。

**Default path:** P0 → P1 → P2；P3 可选。

---

## 依赖关系（总览）

```text
P0 配置/Token
 └─► P1a 服务端 /v1/chat/completions + RulesCompat
 └─► P1b 游戏 PromptAssembler + LlmResponseParser + Http 客户端
       └─► P2 AiGateway 切换 + ai_vs_ai 联调 + 测试
             └─► P3（可选）真 LLM / batch chat / 短历史
```

---

## P0 — 配置与 Token 打通

### T0.1 扩展 `game_settings.cfg` 的 `[ai]` 段
- [x] 在 `data/game_settings.cfg` 增加 `[ai]`：`service_url`、`chat_url`、`api_token`、`protocol`（`v1_tick`|`v2_chat`）、`backend`、`model`、`timeout_sec`、`tick_interval_sec`、`use_local_embedded`、`max_tokens`
- [x] `api_token` 默认留空；注释说明可用 `user://game_settings.cfg` / `AOE2_AI_TOKEN`
- **验收:** 文件可被 `ConfigFile` 解析；无密钥入库

### T0.2 `GameSettings` 加载 AI 配置
- [x] 扩展 `scripts/core/game_settings.gd`：读 `[ai]`，提供 `load_ai_settings() -> Dictionary`（或小型 struct）
- [x] 加载顺序：`user://` → `res://` → 环境变量覆盖（`AOE2_AI_URL`、`AOE2_AI_TOKEN`）
- [x] `GameSession._ready` 调用后把值写入 `GameSession` AI 相关字段（或 `AiConfig.from_game_settings()`）
- **验收:** `tests/test_game_settings.gd` 覆盖 AI 段默认值与 clamp/空 token

### T0.3 `AiConfig` 对齐新字段
- [x] 扩展 `scripts/ai_gateway/ai_config.gd`：`chat_url`、`protocol`、`model`、`max_tokens`、`api_token`（已有 token 则统一命名）
- [x] `from_game_session()` / `save_to_game_session()` / `apply_env_override()` 读写完整
- **验收:** `tests/test_ai_config.gd` 增加 protocol / token 用例

### T0.4（可选同迭代）文明选择 UI 显示 Token
- [x] `civ_select`：可选 LineEdit 绑定 `api_token`（password 模式）；写入 GameSession
- **验收:** UI 改 token 后 `AiConfig.from_game_session()` 能读到

---

## P1a — AI 服务：Chat Completions + RulesCompat

### T1.1 协议模型与 schema 草稿
- [x] 新增 `protocol/ai_v2_chat.schema.json`（或扩展 v1 文件加 `$defs`）：`chat_completion_request` / `chat_completion_response`
- [x] 示例：`protocol/examples/chat_completion_request.json`、`chat_completion_response.json`
- [x] `protocol/CHANGELOG.md` 记录 v2 草案
- **验收:** 示例通过 schema 校验（可用现有/简单 jsonschema 脚本）

### T1.2 Pydantic / FastAPI 模型
- [x] `ai_service_python/protocol/models.py` 增加 Chat Completions 请求/响应模型（`messages`、`tools`、`tool_calls`、`stream`、`metadata`、可选 `observation`）
- **验收:** 非法 body 返回 422；`stream: true` 在路由层拒绝（见 T1.3）

### T1.3 `POST /v1/chat/completions` 路由
- [x] `ai_service_python/main.py` 注册端点；校验 Bearer（复用 `_expected_token()`）
- [x] `stream == true` → `400`；默认按非流式处理
- [x] 结构化日志：model、team/tick（来自 metadata）、tool_call 数量；默认不打满 observation
- **验收:** curl 健康路径 + 带 token/无 token 行为符合设计 §5/§9

### T1.4 `commands` ↔ `tool_calls` 映射
- [x] 新模块如 `ai_service_python/brain/tool_call_mapper.py`
- [x] 正向：Director `commands[]` → `choices[0].message.tool_calls`
- [x] 工具名与设计 §4.5 一致（`gather`/`train`/…）
- **验收:** 单元测试：固定 commands → 期望 tool_calls JSON

### T1.5 RulesCompatBackend
- [x] 从 request 取 `observation`（优先）或 metadata；调用现有 `AiDirector.evaluate`
- [x] 包装为 chat.completion（`finish_reason=tool_calls` 或 `stop`）
- [x] `usage` 可填 0
- **验收:** `opening_eco` fixture 经 chat 端点仍含 `gather`（及既有 train 预期）

### T1.6 Python 测试
- [x] `tests/test_chat_completions.py`：非流式、鉴权、stream 拒绝、RulesCompat parity
- **验收:** `pytest ai_service_python/tests/test_chat_completions.py -v` 通过

---

## P1b — 游戏侧：Prompt / 解析 / HTTP

### T1.7 `PromptAssembler`
- [x] 新文件 `scripts/ai_gateway/prompt_assembler.gd`
- [x] 输入：observation、events、profile/team 元数据
- [x] 输出：`messages`（system + user 文本）、`tools` 列表、`metadata`
- [x] system/user 模板按设计 §4.2–4.3（可先简版固定英文/中文模板）
- **验收:** `tests/test_prompt_assembler.gd`：含经济数字与至少一条 entity 文本

### T1.8 `LlmResponseParser`
- [x] 新文件 `scripts/ai_gateway/llm_response_parser.gd`
- [x] 优先级：`tool_calls` → `content` JSON `commands` → 空
- [x] 输出与现有 Executor 兼容的 `commands[]`（补 `command_id` 若缺失）
- **验收:** `tests/test_llm_response_parser.gd` 覆盖三种变体 + 非法 JSON

### T1.9 `HttpAiClient.post_chat_completions`
- [x] 使用 `config.chat_url`（或 `service_url + /v1/chat/completions`）
- [x] Header：`Authorization: Bearer …`（token 非空时）
- [x] 超时 / 单次重试策略与现有 tick 一致
- **验收:** 可对本地 uvicorn 打通（手动或集成测试）

### T1.10 Tool 目录常量
- [x] 集中定义 tools JSON（GDScript 常量或 Resource），与 Python mapper、设计表一致
- **验收:** 名称集合与 §4.5 一一对应

---

## P2 — 网关切换与联调

### T2.1 `AiGateway` 协议分支
- [x] `protocol == v1_tick`：保持现有 tick / tick_batch
- [x] `protocol == v2_chat`：组 chat 请求 → parse → 仍走 `_pending_responses` / Validator / Executor
- [x] 双队默认 `completions_batch`；`use_tick_batch=false` 时串行两次 chat
- [x] `TICK_INTERVAL` 读配置 `tick_interval_sec`
- **验收:** 配置切换不崩溃；v1 回归现有 Godot AI 相关测试

### T2.2 错误路径
- [x] 超时/5xx/空 choices → 本 tick noop + metrics
- [x] 401 → 按设计：停 AI 或 embedded 回退（与 `use_local_embedded` 一致）
- **验收:** 测试或手动：断网时仿真继续

### T2.3 `ai_vs_ai` 联调
- [x] 确认资源在视野内（已与 match_2d 对齐的 spawn）
- [x] `protocol=v2_chat` + 外部 uvicorn；SETUP 日志带协议名；RulesCompat 回传 debug
- [x] 村民应收到 gather（`cmd_count`/`tool_calls` > 0）
- **验收:** 开局 ECO 可见采集指令；决策面板有 ECON/PROD 类 debug（若服务回传 debug）

### T2.4 Godot 集成 / 回归测试
- [x] 扩展或新增 gateway 测试：mock completion → Executor 调用
- [x] `run_tests.gd` 注册新用例
- [x] Python parity：同一 fixture v1 tick vs v2 chat 命令集合接近
- **验收:** headless `run_tests.gd` + `pytest` 全绿（允许已知无关失败项单独列出）

### T2.5 文档与 README
- [x] 更新 `ai_service_python/README.md`：chat 端点、token、`protocol=v2_chat`
- [x] 设计文档状态改为已实现并链到本任务表
- **验收:** 新人按 README 能跑通 v2

---

## P3 — 可选增强

### T3.1 `completions_batch`
- [x] 服务端 `/v1/chat/completions_batch`；游戏双队单 RTT
- **验收:** 延迟对比串行有改善；行为一致

### T3.2 真 LLM Backend
- [x] `backend=openai`（或兼容 base_url）；透传 messages/tools；解析 tool_calls
- [x] 配置真实 `api_token` / `model`；超时加大
- **验收:** 对小观测能返回合法 gather/train（允许偶发非法被 Validator 丢掉）

### T3.3 短对话历史
- [x] 每队保留最近 K 轮 assistant/tool 摘要（注意 token 预算）
- **验收:** 配置关闭时与无历史行为一致

### T3.4 Debug 观测开关
- [x] 配置 `log_observation=true` 时打印截断 observation / messages 长度
- **验收:** 默认日志仍保持摘要级

---

## 明确不做（本拆解范围外）

- 流式 SSE / WebSocket  
- 模型直接改场景树  
- 完整多轮 ReAct（tool result 多轮）  
- 语音 / 截图多模态  

---

## 建议提交切片

| Commit 切片 | 含任务 |
|-------------|--------|
| `feat(ai): load [ai] settings and token from config` | T0.1–T0.3 |
| `feat(ai-service): add non-streaming chat completions + rules compat` | T1.1–T1.6 |
| `feat(ai): prompt assembler and LLM response parser` | T1.7–T1.10 |
| `feat(ai): gateway v2_chat protocol path` | T2.1–T2.2 |
| `test(ai): chat parity and ai_vs_ai v2 smoke` | T2.3–T2.5 |
| `feat(ai): optional LLM proxy / batch`（可选） | P3 |

---

## 快速对照：谁改哪些文件

| 区域 | 主要路径 |
|------|----------|
| 配置 | `data/game_settings.cfg`、`scripts/core/game_settings.gd`、`game_session.gd`、`ai_config.gd` |
| 协议 | `protocol/ai_v2_chat.schema.json`、`protocol/examples/*`、`CHANGELOG.md` |
| Python | `main.py`、`protocol/models.py`、`brain/tool_call_mapper.py`、`tests/test_chat_completions.py` |
| Godot AI | `prompt_assembler.gd`、`llm_response_parser.gd`、`http_ai_client.gd`、`ai_gateway.gd` |
| 场景联调 | `ai_vs_ai_bootstrap.gd`、README |
