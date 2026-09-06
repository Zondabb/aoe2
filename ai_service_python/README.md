# AoE2 RTS — Python AI Service

独立 Python 进程，实现协议 v1 tick 与 v2 Chat Completions（`/v1/ai/tick`、`/v1/ai/tick_batch`、`/v1/chat/completions`、`/v1/chat/completions_batch`）。

## 依赖

```bash
cd ai_service_python
python -m venv .venv
.venv\Scripts\activate        # Windows
# source .venv/bin/activate   # Linux / macOS
pip install -r requirements.txt
```

## 启动

`uvicorn main:app` 读不到自定义参数。请用 `python main.py`，token 和 host 一样用 `--` 传入：

```bash
cd ai_service_python
python main.py --host 127.0.0.1 --port 8765 --llm-token sk-your-deepseek-key --llm-base-url https://api.deepseek.com
```

常用参数：

| 参数 | 作用 |
|------|------|
| `--host` / `--port` | 监听地址（默认 `127.0.0.1:8765`） |
| `--llm-token` | 上游模型 API token（DeepSeek / OpenAI） |
| `--llm-token-file` | 从文件第一行读 token |
| `--llm-base-url` | 兼容 Chat Completions 的根地址，例如 `https://api.deepseek.com` |
| `--llm-timeout-sec` | 上游超时，默认 30 |
| `--backend` | 强制 `openai` 或 `rules_compat` |
| `--ai-token` | 游戏访问本服务时的 Bearer（可选） |

环境变量 `AOE2_LLM_TOKEN` / `AOE2_LLM_BASE_URL` 仍可用，但命令行优先。系统里设了环境变量后，**必须新开终端**再启动进程才会生效。

健康检查：

```bash
curl http://127.0.0.1:8765/health
# {"status":"ok"}
```

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

在 `data/game_settings.cfg`（或 `user://game_settings.cfg`）设置：

```ini
[ai]
protocol="v2_chat"
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
| `backend=openai` + `--llm-base-url` + `--llm-token` | 透传 messages/tools 到兼容 Chat Completions 的模型；失败且带 observation 时回退规则脑 |
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

- Schema：`protocol/ai_v1.schema.json`（v1 FROZEN）、`protocol/ai_v2_chat.schema.json`（v2 draft）
- 变更日志：`protocol/CHANGELOG.md`
- 示例：`protocol/examples/tick_request.json`

## 范围（P4–P6）

- ✅ GET `/health`
- ✅ POST `/v1/ai/match/start`, `/match/end`, `/tick`, `/tick_batch`
- ✅ POST `/v1/chat/completions`、`/v1/chat/completions_batch`（非流式；RulesCompat / openai 代理）
- ✅ Economy / Production / Build / Army / Combat managers
- ✅ DEFEND 回防 + `threat_near_base` 阶段切换
- ✅ 视野过滤 observation（游戏侧 VisionService）
- ✅ Gateway metrics、Bearer 鉴权、结构化日志
- ✅ Docker / docker-compose
