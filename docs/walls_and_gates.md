# 连续城墙、城门与防守 Agent

选中村民，打开建造菜单选择木墙、石墙或强化城墙，按下左键确定起点，拖动并松开即可下单整排城墙。预览会吸附八个方向，显示整段费用；无效位置或资源不足时不会部分建造或扣费。

- **Shift + 松开左键**：继续从当前终点拖出下一排，可以转弯；新施工任务接在已有队列后面。
- **G**：在当前墙段中央加入/移除城门，至少需要 6 格长度；城门仍需封建时代和石料。
- **R**：单独放置城门时依次切换四个轴向，即 0°、45°、90°、135°。
- **右键 / Esc**：取消当前预览。
- 选中完工城门，可以选择 **自动 / 常开 / 锁闭**。自动模式只由附近友军触发；门内有单位时等待其离开再关闭，避免夹住单位。开着的门允许敌人跟随穿过。

单排最多 64 格。拐角复用己方已有墙段，不重复收费；连接不同材料时保留原墙，不会免费升级。村民逐段完成施工；多选村民可以共同施工。移动、停止、采集或攻击命令会取消该村民后续施工队列；已经支付的地基仍留在场上，可以继续施工。

墙体按方向连接显示。石墙与强化城墙按进度切换原版施工阶段，木栅栏和城门施工使用原版地基。方向、门状态和剩余施工队列支持单机存档；联机由主机验证整排成本、地形、视野和所有权，快照同步方向、施工进度及城门开关。

## 原版素材

木栅栏、石墙、强化城墙和城门使用本机《帝国时代 II HD》基础版 DAT/SLP 资源，支持中国和条顿建筑风格。`data/fortification_sprites.json` 记录资源映射和 DAT SHA-256，`assets/sprites/fortifications/*.json` 记录每帧的原始图形编号、SLP 编号、帧号与叠加偏移；PNG 保留原始像素、阴影与队伍调色遮罩。

墙体选取原版的两种斜墙、横墙、竖墙和端柱：直线按相邻墙段选择方向，端点、转角和交叉口使用端柱，拆掉邻墙后重新连接。城门使用原版四个轴向的门柱及门扇，切换开启/关闭专用图形。原版 96×48 菱形格统一等比缩放到游戏逻辑格 44×22，以保证接缝连续，不对图像旋转或拉伸。预览、点击范围、队伍颜色、遮挡轮廓和迷雾快照均使用这些精灵。

重新导出（需安装 Pillow、NumPy，并提供本机 openage 只读 DAT 解析器目录）：

```powershell
python tools/slp_export/import_fortifications.py --resources "<原版 resources 目录>" --openage "<openage 源码根目录>"
```

导出器跳过已核实的空容器和透明占位帧；缺少实际墙体或门扇文件时直接报错。原版安装目录只读，导出结果存放在项目内。

## AI 如何建墙

Python 的第七个独立角色 `defense` 有自己的规划 schema、状态、事件和任务。默认 `balanced` 在基础经济与军事生产建立后主动修筑基地周界；`reactive` 等待已观察到的基地威胁，`fortify` 优先完成周界。默认总预算为 384 个墙体或城门实体，上限 512，包含地基；达到预算不代表围合。

游戏发送 `decision_context.defense_options`：沿同一个四面相接周界的可见、合法、可接近施工批次，附带村民、起终点、成本、方向和是否含门。AI 只能选择这些候选，不能编造坐标或价格。每批最多覆盖 8 格，优先补毁坏缺口、续接已有墙段。四个方向各有一座自动城门；未解锁时保留出入口，解锁后补门。`defense_plan` 报告真实完工与缺口，`defense_scout_options` 让一名空手村民逐步探明待建边界。完整规划和障碍处理见 [AI 基地防御说明](ai_siege_strategy.md#城镇中心防御)。

防守施工要保留粮食和木材，服从生产、时代与关键建筑预算；不会抢走正在运货、施工或由玩家控制的村民。正在施工的墙不会反复购买，施工队列会随每轮观察发回 Python。村民死亡或施工中断后，空闲村民可以继续未完工部分。本地/内嵌备用 AI 也使用相同周界候选持续围合，并监测探边村民遇敌、停滞和超时。

原子指令：

```json
{"op":"place_wall","builder_id":10,"building_def_id":"stone_wall","start":[20,-6],"end":[20,6],"include_gate":true}
{"op":"set_gate_state","building_id":50,"gate_state":"auto"}
```

`place_wall` 的成功回执包含整排新地基的 `created_entity_ids`。`place_building` 支持 `orientation` 放置单独城门；`append_queue` 用于玩家连续续建。观察中的单位附带 `build_queue_ids`，城门附带 `orientation`、`gate_state`、`gate_open`。

## 观察与验证

重启 Python AI 服务以加载新角色，然后重新开始对局。在日志查看器中选择 `defense` / “城墙防守”，可以看到 `llm_request` 的防线候选与预算、`llm_result` 返回的规划、`plan_applied`，以及最终 `place_wall` / `set_gate_state` 指令。`tick_result.agent_status.defense` 会解释等待原因，比如保留开局粮食和军工、没有安全合法防线或资源不足。

专项检查：`tests/run_wall_controls.gd` 验证真实鼠标/键盘输入；`tests/run_wall_system.gd` 验证整排交易、施工、寻路、门通行、回执、观察和联机权限；`tests/run_fortification_visuals.gd` 验证两文明、三类墙、四方向开关门、连接、队伍颜色、迷雾冻结及点击范围；`tests/run_save_game.gd` 验证保存恢复；`tests/render_walls.gd` 输出 `.godot/walls-preview.png`；Python 的 `tests/test_wall_defense.py` 验证角色预算、可见性、人工控制和任务恢复。

2026-10-23 新增 `tests/run_defense_perimeter.gd`（196 项通过）验证完整基地周界、真实默认地图选线和逐点物理阻挡；`tools/test_ai_perimeter_e2e.py` 的自然施工对局 12 项通过，从零墙体完成全部 214 个墙体/城门实体，并在破坏后重建闭合。过程使用真实迷雾、有限资源、采集和生产；本机模型桩仅返回角色计划，未注入完工进度。完整记录见 [攻城与周界验证](ai_siege_strategy.md#使用和验证)。

原版素材接入后的回归：素材专项 295 项、墙体机制 64 项、建造输入 43 项、全建筑地基 11404 项、迷雾 73 项、迷雾缓存 47 项、选择生命周期 7 项通过；OpenGL 实际渲染已检查四方向接缝、两文明城门开关与木栅栏转角。旧 `run_town_center_occlusion.gd` 仍有 16 项失败，在修改前的 `4a24d4b` 副本中复测得到相同结果。

`tools/test_multi_agent_e2e.py --godot <Godot路径> --duration 1100 --timeout 600 --planner-delay 0.1 --require-walls` 使用实际 Godot 游戏与 HTTP 服务，以及返回有界计划的本地模型桩，要求七角色参与且 AI 真正完成城墙。它不等同于真实 Qwen 对战胜率测试。

2026-10-18 验证结果：Python 308 项通过；鼠标键盘专项 43 项、墙体机制专项 64 项、存档 45 项、联机 AI 权限 55 项、静态寻路 3831 项、迷雾 73 项均通过。1100 游戏秒的 HTTP 整合对局 17 项通过，七角色均参与，AI 完成木墙、训练 15 个士兵并伤害敌方 TC，命令拒绝为 0；结束时尚无胜者。日志保存在 `.godot/multi-agent-e2e-ojgd6yr2/`。

另调用本机真实 `qwen3:8b` 验证新角色：14.59 秒返回 `balanced / stone_wall / max_segments=10 / reserve_wood=18 / gate_mode=auto`，schema 与运行时均接受，完整输入输出在 `.godot/qwen-wall-plan.json`。执行器仍执行至少 60 木材的经济保护下限。

旧的 `tests/run_tests.gd` 总套件仍有 24 项失败和一个旧夹具的离树访问异常；已在修改前的 `4a24d4b` 提交副本复测，得到相同失败列表。上述专项测试与整合对局单独通过。
