# 交接说明：AI 战略智能层（更新于 2026-10-25，家里电脑）

设计、行为与全部实验结果：[../ai_strategic_intelligence.md](../ai_strategic_intelligence.md)。进展报告（Claude Doc）：https://claude.ai/artifact/7XenQZGBV9unR5SFNYeY1m ，其离线副本 [2026-10-23-ai-strategic-intelligence-progress.md](2026-10-23-ai-strategic-intelligence-progress.md) 停留在 10-23 晚的版本。

## 当前状态

- Python 全量 428 项测试通过（家里电脑，Windows 虚拟环境）。
- `plan_review` 与克制推荐修复已合并到 `runtime.py`，新增 `tests/test_plan_review.py`；`tools/ai_duel_ab.py` 新增 `--baseline-dir` 与 `--seed`；已提交。
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
| 防骚扰整局对打修复前（2400 秒，`--baseline-dir`） | 3 胜 1 负；更保守的反击判断（未采用）为 1 胜 1 负 2 平 |
| `plan_review`（qwen3:8b 版本对打） | 合法建议采纳 35/35，计划改动 33 → 54；胜负 2–2，四局都是 0 号队伍获胜 |
| 对战工具 | `tools/ai_duel_ab.py` 新增 `--llm-config`、`--parallel`、`--calls-per-minute`、`--service-dir`、`--indices` |
| 分析脚本 | `tools/duel_analysis/analyze_llm.py`、`compare_openings.py` |
| 原始报告 | `docs/progress/duel-results/`：`batch3-deterministic`、`llm-qwen3`、`opening-main`、`opening-fix1`、`opening-fix2`、`raid-main`、`raid-fix3`、`raid-analysis.txt`、`versus-raid`、`versus-raid-conservative`、`versus-review-llm` |

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

1. 持续骚扰：对方士兵长时间留在经济区时，村民反复撤退拖垮经济；需要把村民转到安全资源或集中兵力清场。
2. 出生位置偏差：最近 10 场决出胜负的版本对打有 9 场是 0 号队伍获胜。疑似单位按场景树顺序处理造成先手优势（实际游戏可能同样存在），先用镜像对局确认，再决定是否修改模拟。
3. 在克制推荐修复后重新测量 `plan_review`，并用更多地图与种子判断它对胜率的影响。
4. 统计显著性：每批 4 局只代表 4 种配置，可以用 `--seed` 增加地图。
5. 待决定：是否在 `scripts/data/game_catalog.gd` 中为所有兵种启用类别加成（恢复原版克制，影响玩家平衡）。
