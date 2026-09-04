# AI vs AI 验证场景

双 AI 自动对战（中国 vs 条顿），右侧实时显示 AI 决策日志，控制台同步打印。

## 运行

在 Godot 中打开并运行 `scenes/ai_vs_ai.tscn`，或临时将 `project.godot` 的 `run/main_scene` 指向该场景。

从 **文明选择**（`scenes/civ_select.tscn`）进入 `match_2d` 时，可在开局前配置 AI 服务。

## AI 服务配置

| 设置 | 说明 |
|------|------|
| **AI 服务地址** | 留空 → 内嵌本地 `http://127.0.0.1:8765`；填远程 URL 则优先连外部服务 |
| **使用内嵌本地 AI 服务** | 勾选时：进程内 `AiServiceAdapter` 直接决策（可选 HTTP shim）；不勾选时：经 HTTP 连外部 Python 服务 |

### 外部 Python 服务（P4）

```bash
cd ai_service_python
pip install -r requirements.txt
uvicorn main:app --host 127.0.0.1 --port 8765
```

游戏侧取消「使用内嵌本地 AI 服务」，地址填 `http://127.0.0.1:8765`，再运行 `ai_vs_ai.tscn`。详见 `ai_service_python/README.md`。

环境变量 `AOE2_AI_URL` 可覆盖 `GameSession` 中的地址（适合 CI / 命令行，会关闭内嵌回退）。

对局内右上角（`ai_vs_ai`）显示：`AI online \| URL \| tick 延迟 ms`。

## 架构（P2+）

- **AiGateway**：每 0.5s 组装 observation → HTTP 或内嵌 adapter → 延迟 1 tick 执行 commands
- **LocalAiServer / Python**：默认内嵌 GDScript adapter；可选 `ai_service_python`（FastAPI @8765）
- 决策经 **CommandExecutor** 执行，不再由场景内 AiDirector 直接 `command_*`

## 日志格式

```text
AI: [t=12.5s] Chinese | PHASE | ECO → BOOM (村民=8 军队=0 食物=210)
AI: [t=13.0s] Teutons | BUILD | 放置 barracks @ (-48, -40)
```

## 相关文档

- 设计说明：`docs/superpowers/specs/2026-08-14-ai-system-design.md`（进程内 AI）
- **AI 服务分离（HTTP / 本地·远程）：** `docs/ai-service-design.md`

## 常见现象

浆果采完后村民「全停」：旧逻辑用资源**中心点**判断采集距离，金矿碰撞盒又过大，村民站在边缘却永远进不了采集。现已按接近点测距，并把金矿阻挡收成 2×2；食物耗尽后 AI 会优先改派木头/金子。
