# 本地 Qwen3 决策排查与优化

排查日期：2026-10-17。原始证据来自 `ai_service_python/logs/multi_agent.jsonl`，截至当日 11:52:33 的记录；后续测试会向该日志追加内容。原始部分另存为本机 `ai_service_python/logs/multi_agent_before_qwen_fix.jsonl`，可复核原始统计。

## 原因与证据

原日志共有 86 次模型返回，仅 17 次应用（19.8%）；独立检查输出后，31 次合法、55 次无效。`state` 不是合法率：旧代码先解析，再用过期或目标变化覆盖原因，部分过期返回同时存在格式错误。

最近两局 28 次返回中，10 次合法、3 次应用（10.7%）；18 次过期、5 次无效、2 次目标变化。延迟中位数 104.19 秒，最大 144.03 秒。游戏速度为 2，180 游戏秒的计划期限只约 90 墙钟秒；18 次过期计划已落后 182–287 游戏秒。

本地 Ollama 版本 0.34.2，模型 `qwen3:8b`（8.2B、Q4_K_M）。排查时 `/api/ps` 报告上下文为 4096；兼容接口请求还保留了 2048 输出预算。最新 8 次输入 token 恰为 2050，且全部没有工具调用，结合模型开始解释输入残片的现象，强烈指向上下文截断。

原请求向 `/v1/chat/completions` 发送强制 `tool_choice` 和 `think:false`，但最近 28 次返回仍含共 122,658 字符的 reasoning。兼容接口的功能与原生接口不同，不能假设参数被执行。官方说明见 [OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)、[Ollama chat](https://docs.ollama.com/api/chat)。

此外，模型只能调整有限的高层参数，单位操作由快速执行器完成。原输入没有全军统计和其他角色计划，提示又偏向维持现状。`applied` 包含重复默认值，实际作用难以区分。首波集结规模会冻结，后续模型的规模调整影响下一波；这一机制保留，并明确告诉模型。

## 已实现

- 本地默认端口 11434 的单一 `propose_plan` 请求使用原生 `/api/chat`，提供完整 `format` schema、`think:false`、显式 `num_ctx=8192`、最多 256 输出 token。
- 启动脚本将本地 GPU 模型并发设为 1，避免多角色同时推理相互等待；远程服务保留原输出预算。
- 角色上下文共享计划、完整兵种数量、工人分配与需求；去除重复敌情、冗长目录和候选明细，按完整记录裁剪。
- 接受完整且通过相同 schema 的 JSON 计划；解说、截断、额外指令和非法字段继续拒绝。兼容 JSON Schema 的整数写法 `6.0` 被规范为 `6`。
- 经济、建设、科技不会仅因发现敌 TC 丢弃参数计划；终局不启动新的模型请求。
- 记录输出合法性、实际变更字段、提交观察序号、计划来源和版本；相同计划明确记为确认，避免冒充策略变化。

## 验证与使用

首次用原始建设上下文调用原生接口：14.353 秒，输入 2717、输出 35 token，思考内容为 0，计划通过 schema 验证。另用新上下文完成六角色真实 Qwen 回放，均可应用到角色运行时；预热后耗时 1.434–2.106 秒、中位数 1.628 秒，详见本机 `ai_service_python/logs/qwen3_verification.jsonl`。

最终 Python 全量回归 266 项通过，含相同观察下不同经济目标、建造人数和战略姿态的实际命令对照。另完成两轮 Godot 1200 游戏秒对局，一轮连接延迟模型桩，一轮连接本地真实 Qwen，两轮均为 16 项检查、0 失败。

真实 Qwen 对局 `multi-agent-real-match-1967830` 中，六角色共 12 次调用，12 次通过校验且成功应用；耗时中位数 1.825 秒、最大 2.317 秒，没有过期或非法计划。其中 2 次改变了参数（战略 stance、科技 target_age/budget_fraction），其余确认原计划。军队实际出征并伤害敌 TC，进入封建时代，游戏命令拒绝为 0；模型规划期间快速 HTTP p95 为 32.5 ms。日志与摘要位于本机 `logs/qwen3_live_verification.jsonl`、`logs/qwen3_live_summary.json`，游戏证据位于 `.godot/qwen3-live-verification/`。

这些结果验证格式、时延、计划提交和执行链路；1200 秒测试结束时未分出胜负，不代表对战胜率提升。模型仍负责有界高层计划，具体行动由执行器依据真实可用条件推进。

启动：

```powershell
cd E:\workspace\aoe2\ai_service_python
.\start_qwen3_proxy.ps1
```

更新服务后开始新对局。检查 `model_result` 的 `parse_state=valid`、`state=applied`、`changed_fields` 与角色的 `plan_source=llm`；重复确认的计划应有空 `changed_fields`。

统计：

```powershell
E:\workspace\aoe2\ai_service_python\.venv\Scripts\python.exe E:\workspace\aoe2\ai_service_python\tools\analyze_multi_agent_log.py
```

模型名、上游地址、生成参数和默认原生上下文统一放在 `ai_service_python/config.toml` 的 `[llm]`；私有覆盖使用 `config.local.toml`。启动脚本会读取这些配置，不再强制覆盖为 `qwen3:8b`。可用环境变量 `AOE2_LLM_NUM_CTX` 或显式 `-NumCtx` 覆盖上下文；自定义 Ollama 端口或反向代理地址目前继续走兼容接口，自动原生适配限定本机标准端口。
