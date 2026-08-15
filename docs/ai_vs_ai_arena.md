# AI vs AI 验证场景

双 AI 自动对战（中国 vs 条顿），右侧实时显示 AI 决策日志，控制台同步打印。

## 运行

在 Godot 中打开并运行 `scenes/ai_vs_ai.tscn`，或临时将 `project.godot` 的 `run/main_scene` 指向该场景。

## 内容

- **ChineseAi**：控制 `Enums.Team.PLAYER`（中国文明）
- **TeutonsAi**：控制 `Enums.Team.AI`（条顿文明）
- 共享 `AiDecisionLog`：阶段切换、建造、训练、集结、战斗命令

## 日志格式

```text
AI: [t=12.5s] Chinese | PHASE | ECO → BOOM (村民=8 军队=0 食物=210)
AI: [t=13.0s] Teutons | BUILD | 放置 barracks @ (-48, -40)
```

## 相关文档

- 设计说明：`docs/superpowers/specs/2026-08-14-ai-system-design.md`

## 常见现象

浆果采完后村民「全停」：旧逻辑用资源**中心点**判断采集距离，金矿碰撞盒又过大，村民站在边缘却永远进不了采集。现已按接近点测距，并把金矿阻挡收成 2×2；食物耗尽后 AI 会优先改派木头/金子。
