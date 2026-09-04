# AoE2 RTS — Python AI Service

独立 Python 进程，实现协议 v1 的 HTTP AI 接口（`/v1/ai/tick`、`/v1/ai/tick_batch`）。

## 依赖

```bash
cd ai_service_python
python -m venv .venv
.venv\Scripts\activate        # Windows
# source .venv/bin/activate   # Linux / macOS
pip install -r requirements.txt
```

## 启动

```bash
cd ai_service_python
uvicorn main:app --host 127.0.0.1 --port 8765
```

健康检查：

```bash
curl http://127.0.0.1:8765/health
# {"status":"ok"}
```

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
3. 运行 `scenes/ai_vs_ai.tscn`（默认 `ai_use_tick_batch=true`，双 AI 单次 RTT）
4. 右上角 AiGatewayStatus 应显示 `online`

## 协议

- Schema：`protocol/ai_v1.schema.json`（v1 FROZEN）
- 变更日志：`protocol/CHANGELOG.md`
- 示例：`protocol/examples/tick_request.json`

## 范围（P4–P6）

- ✅ GET `/health`
- ✅ POST `/v1/ai/match/start`, `/match/end`, `/tick`, `/tick_batch`
- ✅ Economy / Production / Build / Army / Combat managers
- ✅ DEFEND 回防 + `threat_near_base` 阶段切换
- ✅ 视野过滤 observation（游戏侧 VisionService）
- ✅ Gateway metrics、Bearer 鉴权、结构化日志
- ✅ Docker / docker-compose
