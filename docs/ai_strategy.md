# AI 出兵与作战

普通资源、真实采集和战争迷雾下，AI 会建设兵营、持续训练部队、主动搜索敌军并攻击基地。Godot 本地 AI、内嵌适配器和 Python rules 服务均覆盖这些行为。

前期木材优先支撑伐木场和兵营，基础生产设施建成前维持一块农田，避免农田反复消耗全部木材。经济管理会逐步调配空手村民到缺人的资源，保护交付、建造和资源搜索中的村民。村民目标随时代增长到 8 / 12 / 16 / 20；农田随实际劳动力增加。

训练会尝试所有空闲生产建筑，优先主力和文明特色单位；资源不足时选择可负担的替代兵种。升时代资源储备只在经济、基础兵力和建筑条件具备后启用，基地受袭时优先恢复兵力。人口接近上限时提前建房。同一决策内的训练、建造和研究共享资源与人口预算，避免重复使用建筑和村民。

有效攻击命令不会被集结覆盖。基地受袭时各阶段都能转入防守，优先拦截基地范围内的可见敌军；未发现敌人时，军队按公开地图几何搜索，并跳过停滞的搜索点。Python 建造规划收到己方视野圆与迷雾网格参数，检查整个建筑占地的当前可见性，不使用隐藏敌方信息。

协议新增兼容性可选字段：`economy.pop_reserved` 表示队列预留人口；`placement_visibility` 提供 `origin`、`cell_size`、`grid_size` 和己方 `sources`（每项为 x、y、视野半径）。旧观察数据省略这些字段仍可使用。

## 验证

Godot 控制台执行：

```text
godot --headless --path . --script res://tests/run_ai_production_strategy.gd
godot --headless --path . --script res://tests/run_ai_combat_strategy.gd
godot --headless --fixed-fps 60 --path . --script res://tests/run_ai_strategy_match.gd
godot --headless --path . --script res://tests/run_progression_ai.gd
godot --headless --path . --script res://tests/run_ai_farm_supply.gd
```

Windows 沙箱运行时可增加 `--log-file <工作区内绝对路径>`。策略对局测试使用默认地图和起始资源，真实进行采集、建造、研究、训练、移动与战斗；不会赠送资源或瞬间完成建筑。默认检查中国本地 AI 和条顿内嵌适配器。

Python 服务测试：

```text
cd ai_service_python
python -m pytest tests -q
python main.py --host 127.0.0.1 --port 9876 --backend rules_compat
```

服务运行后，从项目根目录执行实际 HTTP 联调：

```text
godot --headless --fixed-fps 60 --path . --script res://tests/run_ai_strategy_match.gd -- chinese python 900
godot --headless --fixed-fps 60 --path . --script res://tests/run_ai_strategy_match.gd -- teutons python 900
```

2026-10-12 验证：Python 115 项通过；Godot 生产 17 项、作战 19 项、农田 29 项及时代发展 1350 项通过。900 秒有限资源对局中，本地中国训练 13 个新兵、条顿适配器训练 10 个；Python 中国训练 14 个、条顿训练 10 个。四组均向敌方推进并造成城镇中心伤害，捕获命令无拒绝。原版本同条件条顿到 900 秒仍无兵营、无新兵、无出击。

Godot 全量 `run_tests.gd` 仍有 24 项原有失败；隔离 HEAD 对照得到完全相同的失败项，涉及旧同步测试中的采集、建造、单位初始化和精灵配置。专项策略测试使用正常初始化的真实实体，单独验证本次行为。
