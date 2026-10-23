# AoE2 RTS — Python AI Service

独立 Python 进程，实现 v3 多 Agent 快速决策（`/v3/ai/tick`），兼容 v1 tick 与 v2 Chat Completions（`/v1/ai/tick`、`/v1/ai/tick_batch`、`/v1/chat/completions`、`/v1/chat/completions_batch`）。

游戏默认启用七角色 AI：战略、建设、经济、科技、侦察、作战、城墙防守。每个快速观察都推进任务，`backend=openai` 在有界后台线程中调用外部模型更新专业计划。防守 Agent 使用游戏提供的可见合法墙线，整排建墙并维护城门与建造队列；基础经济、军事生产和科技储蓄先于墙体投资。完整配置、事件语义和实际限制见 [多 Agent AI 实现说明](../docs/multi_agent_ai.md)。更新后请重启 Python 服务并开始新对局。

```ini
[ai]
service_url="http://127.0.0.1:8765"
protocol="v2_chat"
use_local_embedded=false
multi_agent_enabled=true
fast_tick_interval_sec=1.0
fast_timeout_sec=3.0
```

这是游戏侧 `data/game_settings.cfg` 的配置。开启 `multi_agent_enabled` 后，外部模型模式自动走 v3；原有 `protocol="v2_chat"` 可保留。单人和联机的 AI 托管也使用此通道。需要回归旧版时设置 `multi_agent_enabled=false`、`protocol="v2_chat"`。

模型名称、上游地址、密钥、后端和生成参数统一由 Python 服务管理。游戏只保存连接本服务的地址、可选访问凭据和控制节奏；旧游戏配置中的 `model`、`backend`、`llm_base_url`、`max_tokens`、`history_turns`、`log_observation` 不再生效。

## 服务配置

两份配置启动两个服务、在联机中分别指定队伍地址进行模型对战，见 [LLM 模型对战说明](../docs/llm_model_comparison.md)。

编辑服务目录的 `config.toml`，重启 Python 服务后生效。从其他工作目录启动时也会读取这个文件：

```toml
[service]
host = "127.0.0.1"
port = 8765
log_observation = false

[llm]
backend = "openai"
model = "qwen3:8b"
base_url = "http://127.0.0.1:11434/v1"
max_tokens = 2048
temperature = 0.2
timeout_sec = 30
num_ctx = 8192
```

`backend="openai"` 表示兼容上游模型；要使用纯规则策略，在服务端改为 `rules_compat`。`base_url` 是模型服务的地址，游戏的 `service_url` 是本 Python 服务的地址，两者用途不同。

私有模型或密钥可以写入 `config.local.toml`（已忽略 Git 和 Docker 构建），格式见 `config.local.example.toml`。例如远程模型：

```toml
[llm]
model = "上游提供的模型名称"
base_url = "https://你的模型服务/v1"
token = "你的上游密钥"
```

服务端覆盖顺序：**命令行 > 环境变量 > `config.local.toml` > `config.toml` > 内置默认值**。可通过 `python main.py --config /path/config.toml` 或 `AOE2_AI_CONFIG` 选择其他主文件；对应私有覆盖文件为同目录的 `config.local.toml`（自定义名称时为 `名称.local.toml`）。

游戏中的 `api_token` 只用于访问 Python 服务，对应服务端 `[service].api_token` / `AOE2_AI_TOKEN`，不是上游模型密钥。换模型只修改 Python 端，无需重配每个游戏客户端。请求中的 `model="aoe2-service"` 是协议占位，日志里的上游请求会使用服务端实际模型名。

内嵌规则 AI 使用专用 `embedded_rules.toml` 和独立本机端口，不复用已经运行的外部 LLM 服务。

城墙防守分批完成四面相接的基地周界，保留四向城门、探明待建边界并修复缺口，默认总预算为 384 段。攻城部队拆墙与城镇中心，普通士兵清兵并压制敌方村民。周界规划、经济储备、工坊前置和回防分工见 [AI 攻城与防御说明](../docs/ai_siege_strategy.md)。

## 依赖

Python 3.11 或更新版本（配置读取使用标准库 `tomllib`）。

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

七角色规划自动使用 Ollama 原生 `/api/chat`：JSON Schema 约束、`think=false`、默认 8192 上下文、最多 256 输出 token；启动脚本限制单个 GPU 同时一个请求。这样避免兼容接口忽略 `tool_choice`、思考耗尽输出预算和长观察被截断。调整配置的 `num_ctx`，或显式传 `-NumCtx 16384` 覆盖；启动脚本会读取服务配置中的模型和上游地址。其他兼容服务继续走原接口。详细排查与实测见[Qwen3 决策排查](../docs/qwen3_decision_diagnosis.md)。

直接启动会自动加载服务配置：

```bash
cd ai_service_python
python main.py
# 或使用 ASGI 启动；监听地址由 uvicorn 参数指定，模型仍读取服务配置
uvicorn main:app --host 127.0.0.1 --port 8765
```

Kuailu-LLM（`test-newapi.kuailutech.cn`）示例：

```bash
python main.py --host 127.0.0.1 --port 8765 --backend openai \
  --llm-token sk-your-openai-format-key \
  --llm-base-url https://test-newapi.kuailutech.cn/v1 \
  --llm-model 你的模型名称
```

模型名以所用上游实际开放的名称为准，在 Python 服务配置或 `--llm-model` 中填写。`base_url` / `--llm-base-url` 不要带 `/chat/completions`。

常用参数：

| 参数 | 作用 |
|------|------|
| `--config` | 服务配置文件路径；默认服务目录 `config.toml` |
| `--host` / `--port` | 监听地址（默认 `127.0.0.1:8765`） |
| `--llm-token` | 上游模型 API token（DeepSeek / OpenAI / Kuailu OpenAI 格式密钥） |
| `--llm-token-file` | 从文件第一行读 token |
| `--llm-base-url` | 兼容 Chat Completions 的根地址，例如 `https://api.deepseek.com` 或 `https://test-newapi.kuailutech.cn/v1` |
| `--llm-model` | 覆盖服务配置中的模型名，例如 `qwen3:8b` |
| `--llm-timeout-sec` | 上游超时，默认 30 |
| `--llm-max-tokens` / `--llm-temperature` | 覆盖生成预算和采样温度 |
| `--llm-num-ctx` | 覆盖本机 Ollama 上下文窗口 |
| `--log-observation` / `--no-log-observation` | 启用或关闭观察摘要日志 |
| `--log-dir` | 日志目录；相对路径以所选配置文件目录为起点，两个服务应使用不同目录 |
| `--backend` | 强制 `openai` 或 `rules_compat` |
| `--ai-token` | 游戏访问本服务时的 Bearer（可选） |

环境变量 `AOE2_LLM_TOKEN` / `AOE2_LLM_BASE_URL` / `AOE2_LLM_MODEL` / `AOE2_LLM_MAX_TOKENS` / `AOE2_LLM_TEMPERATURE` / `AOE2_LLM_TIMEOUT_SEC` 仍可用，但命令行优先。原生 Ollama 规划还读取 `AOE2_LLM_NUM_CTX`（默认 8192，范围 2048–32768）。系统里设了环境变量后，需在新终端中启动进程才会读取新值。

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

Chat Completions（非流式；服务端配置 `backend="rules_compat"` 时使用 `observation` 跑现有 Director）：

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
```

然后运行 `scenes/ai_vs_ai.tscn`。Gateway 会走 Chat Completions（双队默认 `completions_batch`）。后端仍由 Python 的 `[llm].backend` 决定。决策面板 SETUP 行会带 `(v2_chat)`。

可选：

| 配置 / 环境变量 | 作用 |
|-----------------|------|
| 服务配置 `[service].log_observation=true` / `AOE2_AI_LOG_OBSERVATION=1` | 打印 messages 长度与 entity 数量（不打满 observation） |
| 服务配置 `[llm].backend="openai"` | 使用服务端模型配置规划；上游失败时继续已建立的计划 |
| 游戏 `timeout_sec=120` | 旧版同步 HTTP 超时；与服务端模型 `timeout_sec` 分开设置 |

Python 为每队保存战略和任务记忆，不再依赖游戏拼接 `history_turns` 条摘要。

## Docker（P6）

```bash
cd ai_service_python
docker compose up --build
```

Compose 挂载服务目录的 `config.toml`，不会强制覆盖其中的上游地址。容器访问宿主机 Ollama 时，将服务配置的 `base_url` 改为 `http://host.docker.internal:11434/v1`，并设置 `[llm].token="ollama"`（本机 Ollama 的占位值）；也可以在运行 Compose 的终端通过 `AOE2_LLM_BASE_URL`、`AOE2_LLM_TOKEN` 覆盖。Linux 已配置 host-gateway。容器里的 `127.0.0.1` 指向容器自身。

远程模型直接填写对应服务地址和真实密钥。模型名与密钥也可通过 `AOE2_LLM_MODEL`、`AOE2_LLM_TOKEN` 覆盖。私有 `config.local.toml` 不会打进镜像；如使用该文件，显式只读挂载到容器 `/app/config.local.toml`。

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

2026-10-23 配置迁移验证：Python 全量 358 项通过；Godot 配置、网关、存档和内嵌隔离专项通过；单人及联机托管的 v3 / v2 均通过真实本机 HTTP 联调，模型名取自隔离的服务端配置。联调用模拟上游模型，不消耗模型额度。

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
