# AoE2 RTS — Python AI Service (P4)

独立 Python 进程，实现协议 v1 的 `/v1/ai/tick`，提供 **经济循环最小集**（采集 / 改派 / 训练村民 / ECO→BOOM→ATTACK 阶段机）。

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

## 测试

```bash
cd ai_service_python
pip install pytest
pytest tests/ -v
```

## 游戏联调

1. 启动 Python 服务（见上）
2. 在 Godot 中设置 **不使用内嵌 AI**、URL 指向 Python：
   - `GameSession.ai_use_local_embedded = false`
   - `GameSession.ai_service_url = "http://127.0.0.1:8765"`
   - 或在 civ_select 界面取消「使用内嵌服务」并填写 URL
3. 运行 `scenes/ai_vs_ai.tscn`
4. 右上角 AiGatewayStatus 应显示 `online`；浆果采完后 debug 日志应出现 `村民采集 wood`

## 目录

```text
ai_service_python/
  main.py                 # FastAPI 路由
  requirements.txt
  protocol/models.py      # Pydantic 协议模型
  brain/
    stores.py             # ObservationStore / EventStore
    entity_queries.py     # 最近资源查询
    economy_manager.py    # assign_gatherers
    production_manager.py # 训练村民（ECO）
    director.py           # 阶段机 + evaluate
    command_builder.py    # commands / debug 输出
  tests/
    test_economy_food_depleted.py
```

## 协议

与仓库根目录 `protocol/ai_v1.schema.json` 一致。示例请求见 `protocol/examples/tick_request.json`。

## 范围（P4）

- ✅ GET `/health`
- ✅ POST `/v1/ai/match/start`, `/v1/ai/match/end`, `/v1/ai/tick`
- ✅ 经济采集 + 浆果耗尽改派木头
- ✅ ECO / BOOM / ATTACK 阶段机（简化）
- ❌ Build / Army / Combat 全量（P5）
