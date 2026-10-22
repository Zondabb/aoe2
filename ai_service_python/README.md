# AoE2 RTS — Python AI Service

独立 Python 进程，实现 v3 多 Agent 快速决策（`/v3/ai/tick`），兼容 v1 tick 与 v2 Chat Completions（`/v1/ai/tick`、`/v1/ai/tick_batch`、`/v1/chat/completions`、`/v1/chat/completions_batch`）。

游戏默认启用七角色 AI：战略、建设、经济、科技、侦察、作战、城墙防守。每个快速观察都推进任务，`backend=openai` 在有界后台线程中调用外部模型更新专业计划。防守 Agent 使用游戏提供的可见合法墙线，整排建墙并维护城门与建造队列；基础经济、军事生产和科技储蓄先于墙体投资。完整配置、事件语义和实际限制见 [多 Agent AI 实现说明](../docs/multi_agent_ai.md)。更新后请重启 Python 服务并开始新对局。

```ini
[ai]
service_url="http://127.0.0.1:8765"
backend="openai"
use_local_embedded=false
multi_agent_enabled=true
fast_tick_interval_sec=1.0
fast_timeout_sec=3.0
```

这是游戏侧 `data/game_settings.cfg` 的配置。开启 `multi_agent_enabled` 后，外部模型模式自动走 v3；原有 `protocol="v2_chat"` 可保留。单人和联机的 AI 托管也使用此通道。需要回归旧版时设置 `multi_agent_enabled=false`、`protocol="v2_chat"`。

城墙防守现在默认提前修筑小规模防线，攻城部队拆墙与城镇中心，普通士兵清兵并压制敌方村民。工坊前置、攻城预算和回防分工见 [AI 攻城与防御说明](../docs/ai_siege_strategy.md)。

## 依赖

```bash
cd ai_service_python
python -m venv .venv
.venv\Scripts\activate        # Windows
# source .venv/bin/activate   # Linux / macOS
pip install -r requirements.txt
```

## 启动

本地 Ollama `qwen3:8b`：

```powershell
cd ai_service_python
.\start_qwen3_proxy.ps1
```

七角色规划自动使用 Ollama 原生 `/api/chat`：JSON Schema 约束、`think=false`、8192 上下文、最多 256 输出 token；启动脚本限制单个 GPU 同时一个请求。这样避免兼容接口忽略 `tool_choice`、思考耗尽输出预算和长观察被截断。`-NumCtx 16384` 可调整上下文，其他兼容服务继续走原接口。详细排查与实测见[Qwen3 决策排查](../docs/qwen3_decision_diagnosis.md)。

`uvicorn main:app` 读不到自定义参数。请用 `python main.py`，token 和 host 一样用 `--` 传入：

```bash
cd ai_service_python
python main.py --host 127.0.0.1 --port 8765 --llm-token sk-your-deepseek-key --llm-base-url https://api.deepseek.com
```

Kuailu-LLM（`test-newapi.kuailutech.cn`）示例：

```bash
python main.py --host 127.0.0.1 --port 8765 --backend openai \
  --llm-token sk-your-openai-format-key \
  --llm-base-url https://test-newapi.kuailutech.cn/v1
```

游戏侧 `data/game_settings.cfg` 的 `model` 必须用手册开放的模型名（当前为 `deepseek-v4-flash-0731`）；写成 `deepseek-v4-flash` 会收到上游 `503 model_not_found`。`--llm-base-url` 只填到 `/v1`，不要带 `/chat/completions`。

常用参数：

| 参数 | 作用 |
|------|------|
| `--host` / `--port` | 监听地址（默认 `127.0.0.1:8765`） |
| `--llm-token` | 上游模型 API token（DeepSeek / OpenAI / Kuailu OpenAI 格式密钥） |
| `--llm-token-file` | 从文件第一行读 token |
| `--llm-base-url` | 兼容 Chat Completions 的根地址，例如 `https://api.deepseek.com` 或 `https://test-newapi.kuailutech.cn/v1` |
| `--llm-model` | 覆盖游戏传来的模型名，例如 `qwen3:8b` |
| `--llm-timeout-sec` | 上游超时，默认 30 |
| `--backend` | 强制 `openai` 或 `rules_compat` |
| `--ai-token` | 游戏访问本服务时的 Bearer（可选） |

环境变量 `AOE2_LLM_TOKEN` / `AOE2_LLM_BASE_URL` / `AOE2_LLM_MODEL` 仍可用，但命令行优先。原生 Ollama 规划读取 `AOE2_LLM_NUM_CTX`（默认 8192，范围 2048–32768）。系统里设了环境变量后，**必须新开终端**再启动进程才会生效。

健康检查：

```bash
curl http://127.0.0.1:8765/health
# {"status":"ok"}
```

实时观察 LLM 输入摘要、输出计划、实际参数变化和执行器指令：

```powershell
.\.venv\Scripts\python.exe tools\watch_multi_agent_log.py --follow --commands
# 查看最近一次完整输入输出
.\.venv\Scripts\python.exe tools\watch_multi_agent_log.py --last 1 --full-io
```

查看工具只读日志，无需重启服务。完整说明见[LLM 观察指南](../docs/llm_observation.md)；模型返回高层计划，`tick.commands` 是执行器下发的具体游戏命令。

Chat Completions（非流式，`rules_compat` 用 `observation` 跑现有 Director）：

```bash
# 见 protocol/examples/chat_completion_request.json
curl -s http://127.0.0.1:8765/v1/chat/completions -H "Content-Type: application/json" -d @../protocol/examples/chat_completion_request.json
```

`stream: true` 返回 400。`AOE2_AI_TOKEN` 非空时需 `Authorization: Bearer …`（`/health` 除外）。

双队 batch：

```bash
curl -s http://127.0.0.1:8765/v1/chat/completions_batch -H "Content-Type: application/json" -d "{\"requests\":[ ... ]}"
```

## 游戏切到 v2 chat

以下为旧版同步接口配置；新部署优先使用上方的多 Agent 配置。在 `data/game_settings.cfg`（或 `user://game_settings.cfg`）设置：

```ini
[ai]
protocol="v2_chat"
multi_agent_enabled=false
use_local_embedded=false
service_url="http://127.0.0.1:8765"
backend="rules_compat"
```

然后运行 `scenes/ai_vs_ai.tscn`。Gateway 会走 Chat Completions（双队默认 `completions_batch`）。决策面板 SETUP 行会带 `(v2_chat)`。

可选：

| 配置 / 环境变量 | 作用 |
|-----------------|------|
| `history_turns=2` | 每队保留最近 K 条 assistant 摘要 |
| `log_observation=true` / `AOE2_AI_LOG_OBSERVATION=1` | 打印 messages 长度与 entity 数量（不打满 observation） |
| `backend=openai` + `--llm-base-url` + `--llm-token` | 在观察中加入战略记忆和合法行动选项，向模型提供 `set_strategy`，将计划展开为游戏指令；上游失败时继续已建立的计划，旧观察仍可回退规则脑 |
| `timeout_sec=15` | 真 LLM 建议加大超时 |

## Docker（P6）

```bash
cd ai_service_python
docker compose up --build
```

游戏侧设置：

- `GameSession.ai_use_local_embedded = false`
- `GameSession.ai_service_url = "http://127.0.0.1:8765"`

可选鉴权（服务端与客户端需一致）：

```bash
export AOE2_AI_TOKEN=your-secret
# 游戏侧：GameSession.ai_service_token 或同环境变量
```

## 测试

```bash
cd ai_service_python
pytest tests/ -v
```

负载测试（P6-9，默认 5 分钟双队 batch）：

```bash
pip install httpx
python tools/load_test_tick_batch.py --base-url http://127.0.0.1:8765
```

## 游戏联调

1. 启动 Python 服务（或 Docker）
2. 在 Godot 中设置 **不使用内嵌 AI**、URL 指向 Python
3. 运行 `scenes/ai_vs_ai.tscn`（v1 用 `tick_batch`；`protocol=v2_chat` 用 `completions_batch`）
4. 右上角 AiGatewayStatus 应显示 `online`

## 协议

- v3：`POST /v3/ai/tick`，见 [实现契约与变更记录](../protocol/CHANGELOG.md)
- Schema：`protocol/ai_v1.schema.json`（v1 FROZEN）、`protocol/ai_v2_chat.schema.json`（v2 draft）
- 变更日志：`protocol/CHANGELOG.md`
- 示例：`protocol/examples/tick_request.json`

## 范围（P4–P6）

- ✅ v3 七角色快速任务与有界后台模型规划、可靠事件反馈和托管让权
- ✅ GET `/health`
- ✅ POST `/v1/ai/match/start`, `/match/end`, `/tick`, `/tick_batch`
- ✅ POST `/v1/chat/completions`、`/v1/chat/completions_batch`（非流式；RulesCompat / openai 代理）
- ✅ Economy / Production / Build / Army / Combat managers
- ✅ DEFEND 回防 + `threat_near_base` 阶段切换
- ✅ 视野过滤 observation（游戏侧 VisionService）
- ✅ Gateway metrics、Bearer 鉴权、结构化日志
- ✅ Docker / docker-compose
