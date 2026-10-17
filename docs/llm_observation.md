# 观察模型输入、计划和实际指令

从仓库根目录或 `ai_service_python` 目录执行均可。以下命令以服务目录为起点：

```powershell
cd E:\workspace\aoe2\ai_service_python
.\.venv\Scripts\python.exe tools\watch_multi_agent_log.py --follow --commands
```

工具只读日志，启动时显示最近 6 次规划与最近一批指令，随后跟随新日志；按 Ctrl+C 退出。输入输出默认显示摘要，避免完整观察挤满终端。

## 应该分开看的四层

| 层次 | 日志位置 | 含义 |
| --- | --- | --- |
| 模型输入 | `llm_io.input.messages`、`format` 或 `tools` | 实际发送的系统提示、游戏观察、当前计划和输出约束 |
| 模型输出 | 原生 Ollama 的 `llm_io.output.message.content`；兼容接口的 `choices[0].message` | 模型返回的高层计划，例如集结人数、资源比例和科技预算 |
| 是否采用 | `model_result.state`、`parse_state`、`changed_fields` | 计划是否合法、是否提交，以及实际改变了哪些参数 |
| 游戏指令 | `tick.commands` | 执行器依据当前观察和已保存计划下发的移动、采集、建造、训练、攻击、研究等命令 |

`state=applied` 代表计划被采用，`changed_fields=[]` 代表确认原计划。`plan_source=llm` 表示角色已接收模型计划，不能据此把其所有动作都认定为模型的新贡献。

`tick.commands` 代表已下发的命令；是否执行成功，还要看游戏回执和实际状态。现有 Python JSONL 没有逐条完整保存所有游戏 `command_result`，不能只凭日志里出现了 `attack` 就宣称已命中目标，也不能把时间紧邻某个模型返回的指令直接算作该模型导致。

## 展开真实输入输出

```powershell
.\.venv\Scripts\python.exe tools\watch_multi_agent_log.py --last 1 --full-io
```

按查看工具打印的 `request_id` 查询一次调用：

```powershell
.\.venv\Scripts\python.exe tools\watch_multi_agent_log.py --request-id e0f8de3a2cce41eeb505bb3a71fd0165 --full-io
```

如果该记录已轮转，给出对应文件路径；也可以使用上次真实对局保存的独立日志：

```powershell
.\.venv\Scripts\python.exe tools\watch_multi_agent_log.py logs\qwen3_live_verification.jsonl --last 6 --commands
```

`llm_io` 在一次请求结束后写入，因此会在完成后展示完整输入和最终输出。当前非流式接口不会在终端逐 token 展开生成过程。关闭思考后，模型输出主要是计划 JSON，没有完整的内部推理文本。

## 一次真实调用的含义

上次真实对局中，科技角色的输入计划为：

```json
{"target_age":3,"budget_fraction":0.5,"priority":"military"}
```

Qwen 返回：

```json
{"target_age":1,"budget_fraction":0.6,"priority":"military"}
```

日志表明它通过校验并被采用，改变了 `target_age` 与 `budget_fraction`。这次模型做的是调整时代目标和预算；执行器仍需满足资源、前置建筑和队列条件后才能发出 `research_age`。模型提交计划时不会立即生成一条升级命令。

## 游戏里看哪里

- AI 对 AI 观战的右侧决策日志显示角色状态和命令数量；右上角显示连接及快速 HTTP 延迟，这个延迟不是模型推理耗时。
- 观战时点击单位，左下单位调试日志可查看当前命令、位置、采集状态和路径，适合核对实际动作。
- 当前游戏界面尚未展示完整提示词、模型原文或计划差异；这些内容使用上面的日志工具查看。

总体统计仍用 `tools/analyze_multi_agent_log.py`，适合判断成功率、延迟和参数变化次数；`watch_multi_agent_log.py` 用于逐次观察。
