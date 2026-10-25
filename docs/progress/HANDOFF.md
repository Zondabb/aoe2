# 交接说明：AI 战略智能层（更新于 2026-10-25，家里电脑）

设计、行为与全部实验结果：[../ai_strategic_intelligence.md](../ai_strategic_intelligence.md)。进展报告（Claude Doc）：https://claude.ai/artifact/7XenQZGBV9unR5SFNYeY1m ，其离线副本 [2026-10-23-ai-strategic-intelligence-progress.md](2026-10-23-ai-strategic-intelligence-progress.md) 停留在 10-23 晚的版本。

## 当前状态

- Python 全量 421 项测试通过（家里电脑，Windows 虚拟环境）。
- 村民防骚扰已合并到 `runtime.py`，新增 `tests/test_raid_response.py`（10 项）与 `tools/duel_analysis/raid_losses.py`，已单独提交。
- 开局经济修复在 `151931b`；并行的 GDScript 性能改动已在 `4f33b9c`、`a5726c9` 提交。
- 关闭新层：`AOE2_AI_INTELLIGENCE=off`。

## 本轮做了什么

| 项目 | 结果 |
| --- | --- |
| 确定性 A/B（当前战术，4 局 2400 秒） | 开启方 1 胜 0 负 3 平，交换略差 |
| 本机 qwen3:8b A/B（4 局 2400 秒） | 开启方 2 胜 1 负 1 平，损失 15885 / 击杀 20890 |
| 开局经济修复 | 兵营平均提前约 230 秒，首个士兵提前约 150 秒，封建时代 4 队中 3 队更早 |
| 村民防骚扰（900 秒，配置 0–3） | 损失村民 17 → 4，900 秒村民 103 → 122；兵营晚约 9 秒、首个士兵晚约 17 秒，军队产出少 12% |
| 对战工具 | `tools/ai_duel_ab.py` 新增 `--llm-config`、`--parallel`、`--calls-per-minute`、`--service-dir`、`--indices` |
| 分析脚本 | `tools/duel_analysis/analyze_llm.py`、`compare_openings.py` |
| 原始报告 | `docs/progress/duel-results/`：`batch3-deterministic`、`llm-qwen3`、`opening-main`、`opening-fix1`、`opening-fix2`、`raid-main`、`raid-fix3`、`raid-analysis.txt` |

注意：LLM 批次第 2、3 局和三组开局对比在上述并行 GDScript 改动之后启动，确定性批次和 LLM 第 0、1 局在之前。

## 复现

```powershell
cd ai_service_python; .\.venv\Scripts\python.exe -m pytest tests -q -p no:cacheprovider; cd ..
# 无模型 A/B
ai_service_python\.venv\Scripts\python.exe tools\ai_duel_ab.py --godot "<Godot 控制台程序>" --matches 4 --duration 2400 --timeout 7200
# 本机 qwen3:8b A/B（先确认 Ollama 在运行；单卡每次 2 局）
ai_service_python\.venv\Scripts\python.exe tools\ai_duel_ab.py --godot "<Godot 控制台程序>" --matches 4 --parallel 2 --duration 2400 --timeout 18000 --llm-config ai_service_python\config.toml
# 开局对比
ai_service_python\.venv\Scripts\python.exe tools\duel_analysis\compare_openings.py main=<目录> fix=<目录>
```

家里电脑的 Godot：`E:\Program Files\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`；办公室为 4.7.1。家里电脑同时运行 8 局时约 0.2–0.3 游戏秒/秒，运行 4 局时约 2.4 游戏秒/秒。

家里电脑工程根目录的 `_run_*.bat` 是本次在 Windows 上启动脚本用的本地入口，已写入 `.git/info/exclude`，可以删除。`.godot/home-run/`、`.godot/opening-fix*/` 是临时目录（被 git 忽略）。

## 下一步

1. 防骚扰的整局效果：用 2400 秒对局比较修复前后版本的胜负（需要让两队使用不同的服务目录）。
2. 模型很少修改计划（每局 120–210 次调用改 0–8 次）：可以在提示中加入“上次计划以来的变化”作为必须回应的项目，或降低确认已有计划的调用频率。
3. 统计显著性：每批 4 局只代表 4 种配置，需要更多地图与种子。
4. 待决定：是否在 `scripts/data/game_catalog.gd` 中为所有兵种启用类别加成（恢复原版克制，影响玩家平衡）。
