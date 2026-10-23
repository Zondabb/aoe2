# 交接说明：AI 战略智能层（2026-10-23 晚，办公室 → 家）

进展报告（含详细过程）：[2026-10-23-ai-strategic-intelligence-progress.md](2026-10-23-ai-strategic-intelligence-progress.md)，在线版 Claude Doc：https://claude.ai/artifact/7XenQZGBV9unR5SFNYeY1m 。设计与行为说明：[../ai_strategic_intelligence.md](../ai_strategic_intelligence.md)。

## 当前状态

- Python 全量 403 项测试通过（`ai_service_python/tests`），其中 `tests/test_strategic_intelligence.py` 23 项。
- 本次提交同时包含你此前未提交的城墙/周界改动（`defense_perimeter.gd`、`wall_system.gd`、存档、相关测试与文档）。`runtime.py` 中两者混在一起，已一并提交。
- 关闭新层：`AOE2_AI_INTELLIGENCE=off`（完全恢复旧战术，且提示词不再附带情报）。

## 本次的主要改动

| 模块 | 内容 |
| --- | --- |
| `brain/multi_agent/combat_model.py` | 复刻游戏伤害公式；分组战斗模拟（实际距离、最小射程盲区、TC 火力）；性价比 |
| `brain/multi_agent/intel.py` | 对手画像、K/D 账本、风格识别 |
| `brain/multi_agent/doctrine.py` | 6 种学说、克制排名、学说推荐 |
| `brain/multi_agent/tactics.py` | 集火（打到死为止，攻城单位可打断）、风筝后回到原目标、远程风筝 |
| `brain/multi_agent/memory_bank.py` | 跨局战绩记忆（`strategy_memory.json`） |
| `runtime.py` / `scheduler.py` / `main.py` | 接入上述模块、LLM 上下文、开关、跨局记忆 |
| `tests/run_ai_duel_match.gd` + `tools/ai_duel_ab.py` | AI 对 AI 的 A/B 对战（新增 `--llm-config`） |
| `tools/duel_analysis/` | 对战日志分析脚本（原在被忽略的 `.godot/` 中） |

## A/B 对战结果

第一批 = **修复集火换目标问题之前**的代码，模型无关的确定性执行器，每局 2400 游戏秒。原始报告与逐分钟曲线：`docs/progress/duel-results/batch1-prefix/`。

| 局 | 开启方 | 结果 | 开启方 损失/产出 | 关闭方 损失/产出 | 结束时兵力 开/关 |
| --- | --- | --- | --- | --- | --- |
| 0 | 中国（队伍 0） | 关闭方（条顿）1801 秒获胜 | 700 / 700 | 1500 / 3205 | 0 / 21 |
| 1 | 条顿（队伍 1） | 开启方（条顿）1969 秒获胜 | 2270 / 3445 | 2730 / 2860 | 15 / 2 |
| 2 | 条顿（队伍 0） | 2400 秒无胜负 | 3700 / 4535 | 3940 / 4535 | 9 / 6 |
| 3 | 中国（队伍 1） | 2400 秒无胜负 | 3300 / 4630 | 4320 / 4920 | 19 / 4 |

结论有好有坏：第 0、1 局开启方更差（根因是集火换目标，已修复）；第 2、3 局开启方战损更少、存兵更多。4 局只代表 4 种配置，不具备统计显著性。

**第三批**（当前代码）18:45 在办公室电脑启动，结果在办公室的 `.godot/ai-duel-oimps9fo/`（被 git 忽略，**没有提交**）。在家可以直接重跑，见下文。

## 在家继续

```powershell
git pull
cd ai_service_python
python -m venv .venv; .\.venv\Scripts\pip install -r requirements.txt   # 若家里尚无环境
.\.venv\Scripts\python.exe -m pytest tests -q -p no:cacheprovider     # 应为 403 passed
cd ..
# 无模型 A/B（约 45 分钟，4 局并行）
ai_service_python\.venv\Scripts\python.exe tools\ai_duel_ab.py --godot "<家里的 Godot 控制台程序>" --matches 4 --duration 2400 --timeout 7200
# 分析
ai_service_python\.venv\Scripts\python.exe tools\duel_analysis\duel_reports.py .godot\ai-duel-<目录>
ai_service_python\.venv\Scripts\python.exe tools\duel_analysis\analyze_switch.py .godot\ai-duel-<目录> 1100
```

注意：

- `ai_service_python/config.ds.toml` 含 API token，**没有提交**。家里需要自行复制或重建；建议把 token 放到被忽略的私有覆盖文件中。
- 用本机 Qwen3 跑 LLM 对战需要先启动 Ollama（`start_qwen3_proxy.ps1`），单卡建议 `--matches 2`；DeepSeek 是付费远程接口。
- 未提交：构建产物 `aoe2.exe/.pck/.console.exe`、`temp_ui_frames/`、`.superpowers/` 日志、`multiplayer_service_python/.env copy.example`。

## 下一步

1. 汇总第三批（或在家重跑），与第一批逐局对比胜负、战损和换目标率（`analyze_switch.py <目录> 1100` 比较同一时间窗口）。
2. 用会发展的 LLM 对手跑 A/B：`--llm-config ai_service_python/config.toml`（本机 Qwen3）或 `config.ds.toml`（DeepSeek，需确认费用）。
3. 待决定：是否在 `scripts/data/game_catalog.gd` 中为所有兵种启用类别加成（恢复原版克制，影响玩家平衡）。
4. 既有问题：开局兵营约 463 秒才完工（与新层无关），是提升 AI 表现的最大杠杆。
5. 把最终结果写入 `docs/ai_strategic_intelligence.md`。
