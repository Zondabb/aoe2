# 阵营颜色设计

日期：2026-09-21

状态：已被 [索引蒙版 + Shader 方案](2026-09-21-team-color-shader-design.md) 取代，保留作为方案比较记录

适用范围：当前 Godot 2D 对战、AI 对战及竞技场中的单位和建筑

## 1. 设计结论

第一阶段采用 **SLP 离线导出多套玩家色贴图，运行时按阵营选择贴图**。默认 PLAYER 使用玩家色 1（蓝），AI 使用玩家色 2（红）。只替换原始素材定义的玩家色区域，例如衣服、旗帜和装饰，保留皮肤、武器、屋顶、阴影的原色。

这个项目已经具备按玩家色解码 SLP 的能力。主要工作是让多个颜色版本同时存在，并把颜色选择贯穿 SpriteCatalog、单位动画和建筑加载流程。当前只有两个阵营，优先复用现有导出及 AtlasTexture 路径；暂不引入运行时换色 Shader。

“阵营”在本文中指实体的 `team`，不指中国、条顿等文明。中国可以是蓝色，也可以是红色；同文明对战也应能区分双方。

## 2. 现状与问题

以下结论来自当前仓库代码，不代表功能已经按本文实现。

| 位置 | 当前行为 | 影响 |
|---|---|---|
| `scripts/core/enums.gd` | `Team { PLAYER, AI }` | 可以直接建立两方颜色映射，无须改变阵营枚举 |
| `scripts/entities/unit_agent.gd::_apply_team_color()` | 对 Body 使用蓝/红色，对 Billboard 使用蓝/红整体 tint | 全图颜色被乘色，皮肤和武器也受影响，无法准确替换已烘焙的玩家色 |
| `scripts/entities/building_agent.gd::_configure_visuals()` | 建筑 Billboard 为 `Color.WHITE`；只有占位 Body 按阵营染色 | 有精灵的建筑使用同一张图片，不能正确区分阵营 |
| `tools/slp_export/slp.py` | 支持玩家色绘制 `0x06`、玩家色填充 `0x0A`，调用 `_player_index()` | 原始素材已经标明哪些像素允许换色 |
| `tools/slp_export/export_sprites.py` | 支持 `player` 参数，但输出始终为 `{key}.png` | 分别导出两种颜色到同一目录会覆盖文件 |
| `tools/slp_export/regenerate_all.py` | `--player` 只选择本次重建的一种颜色 | 不能直接提供同时存在的多阵营资源 |
| `scripts/presentation/sprite_catalog.gd` | 按兵种、动作、文明选择基础资源，不接收颜色参数 | 同一种单位的双方共享同色素材 |
| `scripts/core/match_state.gd` | 保存双方经济、人口和胜负，没有颜色配置 | 缺少每局统一的颜色来源 |

特别注意：当前 `assets/sprites/regenerate_report.json` 记录 `player_color: 3`。这只是最近一次重建报告，不能证明每个文件的实际颜色，但足以说明**不能把旧 PNG 默认认定为蓝色**。迁移时应从 SLP 明确重建 1、2 两套颜色，不能靠对旧图识别蓝色像素进行替换。

当前主入口从文明选择进入 `scenes/match_2d.tscn`，单位和建筑脚本均继承 Node2D。仓库保留的 3D 场景和辅助方法不列为本阶段验收入口。

## 3. 目标与边界

### 必须达到

- 同一兵种、同一文明的两个阵营能以局部玩家色区分。
- 行走、待机、采集、建造、攻击、死亡使用一致的阵营颜色；覆盖当前已有动作。
- 初始建筑、新建建筑和训练出的单位自动继承所属阵营颜色。
- 玩家色改变不影响帧数、热点、翻转、动画时机、碰撞、视野、攻击判定或 AI 协议。
- 阴影透明度、透明背景、调色板索引 0 的黑色细节保持正确。
- 有素材的建筑与无素材的占位建筑都可以辨认归属。

### 本阶段不包含

- 多人外交、联盟、超过两个阵营的战斗逻辑。
- 任意 RGB 自定义衣服颜色、比赛中动态换色、招降功能。
- 新增小地图、战争迷雾、3D 渲染适配或新的文明建筑美术。
- 修改地形、树木、矿石、浆果、普通箭矢及通用 UI 图标的颜色。

资源格式保留玩家色 1～8 的扩展能力；这不等同于游戏已经支持八名玩家。

## 4. 方案比较

| 方案 | 优点 | 成本或问题 | 决策 |
|---|---|---|---|
| 整图 `modulate` | 现成、修改少 | 所有像素乘色，已烘焙色无法准确转换，建筑材质失真 | 只用于占位图及临时状态提示 |
| 对 PNG 按 RGB/色相替换 | 不必重做导出器 | 丢失了 SLP 玩家色语义，可能误染普通像素，也可能漏掉阴影色阶 | 不采用 |
| 离线导出玩家色变体 | 复用现有解码和动画路径；多层建筑可直接按正确颜色合成 | 彩色资源增加包体和纹理内存 | 第一阶段采用 |
| 原图 + 玩家色索引蒙版 + Shader | 能共享底图，适合大量颜色与自定义调色板 | 需要新增蒙版导出、材质、动画图集对应、多层透明合成处理 | 有明确需求或性能证据后评估 |

离线方案的代价主要随“可着色素材数量 × 实际加载颜色数”增长，而非按单位实例数复制纹理。具体包体、显存及渲染开销需要实测，本文不承诺帧率提升。

## 5. 数据设计

### 5.1 每局颜色归属

新增 `scripts/presentation/team_color_catalog.gd`，统一保存默认映射、支持颜色集合以及用于占位图和界面的代表色。`MatchState` 保存本局 `team_color_ids`，提供只读查询 `get_team_color_id(team)`。

建议配置：

```gdscript
# 设计示意，尚未添加到项目。
var team_color_ids: Dictionary = {
    Enums.Team.PLAYER: 1,
    Enums.Team.AI: 2,
}
```

| 数据 | 职责 |
|---|---|
| `team` | 逻辑归属、敌我判断，保持现有定义 |
| `civ.id` | 文明规则和建筑外观选择 |
| `team_color_id` | 原始调色板中的玩家色编号，范围 1～8；本阶段资源仅发布 1、2 |
| `display_color` | 占位 Body、阵营标记使用的单一代表色，不用于替换原始精灵的全部像素 |

`display_color` 初期可集中使用现有蓝、红常量；精灵的明暗色阶仍取自源调色板，不通过这一代表色推导。

### 5.2 初始化与配置来源

1. `MatchState.setup_defaults()` 每次明确重置颜色为蓝/红，避免竞技场重开保留上局值。
2. 第一阶段各入口使用默认映射；不增加重复的 GameSession/实体颜色配置，不要求新增选色 UI。
3. 未来开放选色时，再由 GameSession 或 ArenaConfig 的开局参数一次性传入 MatchState；校验完成后创建实体。本局以 MatchState 为唯一事实来源。
4. 实体通过自己的 `team` 查询颜色；脱离 MatchState 的单体预览/测试使用 TeamColorCatalog 默认值。
5. 无效颜色编号或未发布的颜色配置必须报告配置错误并恢复整局默认蓝/红；双方不得静默得到同一种颜色。未来选色 UI 应阻止重复颜色进入对局。
6. 不把颜色写入 CivDef、UnitDef、BuildingDef，也不改变 AI 请求中的 team 数值。

AI 对战中 PLAYER/AI 仍代表两个逻辑槽位，是否由人类控制不影响颜色。

## 6. 资源导出契约

### 6.1 目录及元数据

保留现有基础路径和 JSON，新增同目录下的玩家色 PNG。基础 PNG 保留为旧调用兼容资源；其颜色由新增字段明确声明，不能靠文件名推断。

```text
assets/sprites/units/archer_walk.png
assets/sprites/units/archer_walk.json
assets/sprites/units/archer_walk_p1.png
assets/sprites/units/archer_walk_p2.png

assets/sprites/buildings/tc_asian_feudal.png
assets/sprites/buildings/tc_asian_feudal.json
assets/sprites/buildings/tc_asian_feudal_p1.png
assets/sprites/buildings/tc_asian_feudal_p2.png
```

在现有 JSON 中追加字段，已有 `cols`、`rows`、`frame_w`、`frame_h`、`frame_count`、`directions`、`frames_per_direction`、`hotspots`、`includes_shadow` 等按原语义保留：

```json
{
  "schema_version": 2,
  "default_player_color": 1,
  "player_color_mode": "variants",
  "player_color_textures": {
    "1": "archer_walk_p1.png",
    "2": "archer_walk_p2.png"
  }
}
```

以上为追加字段示意，不是完整可运行的 manifest。路径相对于 JSON 所在目录，运行时通过资源目录解析；不得写入开发者机器绝对路径。

没有玩家色指令的素材写 `player_color_mode: "none"`，共享基础 PNG，无须生成重复图片。判断依据是解码时是否出现玩家色绘制像素；**不能通过最终 RGB 是否呈蓝色判断**。多层建筑以所有参与图层的结果汇总。

对于缺少新字段的旧 manifest，现有无颜色参数接口继续按旧行为读取；新阵营颜色接口将其视为“颜色身份未知”，不能当作 `none`。迁移验收要求当前使用的所有单位、建筑 manifest 均完成分类。

### 6.2 导出过程

1. 从当前 SpriteCatalog 的单位、村民动作、战斗动作及建筑映射整理一份显式导出清单，按基础路径去重。`villager_chop` 同时被工作及攻击使用，不能遗漏。
2. 对可着色素材分别以 `player=1`、`player=2` 解码；保留现有 `_player_index(base, player)` 计算，禁止先解码一种颜色再按 RGB 猜测替换。
3. 两种颜色使用一致的原始帧尺寸和 `pack_sheet()` 排列；导出器逐项核对尺寸、帧数、热点和方向完全一致。
4. 基础 PNG 明确重建为 p1，记录 `default_player_color: 1`；它与 `_p1.png` 必须像素一致。允许这份兼容副本占用额外包体，运行时新路径只加载变体。
5. 写入所有变体成功后再更新 manifest；失败时命令返回非零，不能以缺失半套资源的状态发布。
6. 报告逐素材记录发布颜色、是否含玩家色、源文件/调色板摘要以及错误，便于核对与增量重建。

新导出入口建议提供 `--team-colors 1,2`，此参数目前不存在。旧 `--player` 保留为单色预览用途；不得在生产目录留下与新版 manifest 不一致的结果。若对新版资源执行单色重建，要求输出到独立预览目录或明确拒绝操作。

`regenerate_all.py` 当前还会扫描已有额外 JSON 并重建弓箭手放大预览。多色生产模式应以显式游戏资源清单为准，避免把额外实验图、UI 和所有预览都乘以颜色数；原单色预览流程继续独立使用。

### 6.3 城镇中心合成与透明度

`export_composited_asian_feudal_tc()` 目前按多个 SLP 图层及热点合成。每个颜色版本都必须先把**全部图层**按同一玩家色解码，再调用现有 `composite_hotspot_images()` 完成 source-over 合成。

不能只替换主楼图层、只更改最终 PNG 的部分 RGB，或改变图层顺序。两种颜色的合成画布、原点、热点和 `includes_shadow` 必须一致。

继续保留现有规则：普通调色板索引 0 为不透明黑色；skip/轮廓及行边界决定透明区域；SLP shadow 像素为黑色、alpha 100。非玩家色区域以及最终整张图的 alpha 应在不同颜色版本间保持一致。

## 7. Godot 加载与缓存

### 7.1 SpriteCatalog 扩展

保留 `unit_sheet_base()`、`building_sheet_base()` 的职责：先确定美术资源，再选择颜色。新增颜色解析接口，避免各实体自行拼 `_p1` 后缀。

建议接口（待实现）：

```text
resolve_team_texture(base, color_id) -> Dictionary
# texture: Texture2D 或 null
# status: variant / invariant / missing_variant / unknown_legacy

get_unit_visual_bundle(unit_id, color_id) -> Dictionary
# frames: 完整 SpriteFrames
# metas: 按动作索引的元数据
# status: ready / unavailable
```

内部更新 `build_villager_sprite_frames()`、`append_unit_combat_frames()` 及普通单位帧构建调用，确保所有动作传入同一个颜色编号。元数据仍按基础路径共享，AtlasTexture 仅换底层纹理，保持原 region、hotspot 和方向翻转规则。

建议缓存键：

| 缓存 | 键 | 约束 |
|---|---|---|
| 元数据 | `base` | 只读共享 |
| 纹理选择结果 | `(base, color_id)` | `none` 类型可复用同一底图 |
| 单位动画资源包 | `(unit_id, color_id)` | 构建完成后只读共享，包含该兵种全部已有动作 |
| 建筑 AtlasTexture | `(base, color_id)` | 不包含实例状态 |

不能只按 unit_id 缓存 SpriteFrames，否则第一次加载的颜色会污染另一个阵营。禁止在已共享的 SpriteFrames 中为单个实例替换帧纹理。动态帧编号、动画计时和翻转仍保存在实体自身。

只在生成实体或首次请求该素材时解析资源，不在 `_physics_process()` 或每次切帧时扫描目录、解析 JSON、生成图片。首阶段可让缓存持续至进程退出；若后续发布八色或大量文明，再评估按场景释放。

### 7.2 缺失资源策略

- 发布前检查当前使用清单的所有颜色及动作，缺失即失败。
- 开发运行时缺少某一必需动作的颜色变体，整个单位回退到阵营色 Body，并按 `(base, color_id)` 只警告一次，避免攻击时突然切回错误颜色。
- 某动作本来没有源素材，沿用原有动作降级规则；区别于“应有变体却未发布”。
- 建筑缺变体时回退阵营色 Body；原本没有建筑精灵的 mill、lumber_camp、mining_camp 继续使用占位显示。
- 经明确分类的 `none` 素材使用共享底图。如果其本身看不出归属，单位/建筑应增加独立的小型阵营标记；标记与选择圈分开，并跟随实体显示/隐藏。基础实现应纳入这种情况的验收。
- 不静默让红方读取 p1，也不将旧版未知颜色 PNG 当作正确颜色使用。

## 8. 实体与状态显示

### 单位

`UnitAgent._setup_presentation()` 在构建动画前取得颜色编号，统一使用对应资源包。成功加载后的 Billboard 保持 `modulate = Color.WHITE`，删除基于 team 的全图 tint；占位 Body 从 TeamColorCatalog 读取代表色。

死亡动画保持死亡前的阵营颜色，不能加载无颜色参数的另一套帧。不改变 `_anim_frame`、朝向和攻击命中/投射物释放时刻。

### 建筑

`BuildingAgent._configure_visuals()` 先根据建筑类型和文明取得 base，再按本局颜色读取纹理。中国和条顿的素材差异保持原样，颜色不参与文明选择。

训练单位已经在加入场景树前设置 `team`、`civ`、`match_state`，直接复用此传递路径。初始生成、AI 建造、玩家放置也需确认这些字段均在视觉初始化前设置。

### 放置预览、选择与血条

| 显示对象 | 规则 |
|---|---|
| 正常单位/建筑精灵 | 原始局部玩家色；整体 modulation 为白色 |
| 占位 Body | 使用阵营代表色 |
| 合法/非法建筑幽灵 | 先选所属阵营贴图，再沿用现有绿/红半透明状态 tint |
| 幽灵转实体 | `clear_ghost_visual()` 后恢复正常贴图及白色 modulation，清空预览状态 |
| 选择圈/占地框 | 保持现有白色，表示选中状态 |
| 血条 | 保持现有生命值含义，不直接换成阵营色 |
| 中立资源、地形、普通箭矢 | 保持原色 |

本阶段不新增受击闪白。以后添加时，应将闪白作为临时效果层处理，结束后恢复正常 modulation，不能重新写入旧阵营 tint。材质或 modulation 不施加到包含阴影、血条和选择圈的实体根节点。

## 9. 改动清单与实施顺序

| 阶段 | 文件/模块 | 完成条件 |
|---|---|---|
| 1：资源契约 | `tools/slp_export/slp.py`、`export_sprites.py`、`regenerate_all.py`、导出 README | 输出玩家色分类、1/2 变体和一致 manifest；单色预览不会破坏生产数据 |
| 2：资源迁移 | `assets/sprites/units/`、`assets/sprites/buildings/`、导出报告 | 当前运行时清单全部分类并通过颜色、帧布局及透明度校验 |
| 3：颜色数据 | 新增 `scripts/presentation/team_color_catalog.gd`；修改 `scripts/core/match_state.gd` | 蓝/红默认值、统一查询、重开重置、无状态时默认映射 |
| 4：视觉资源 | `scripts/presentation/sprite_catalog.gd` | 完整动作包、颜色缓存键、缺失处理及共享资源只读约束 |
| 5：实体接入 | `unit_agent.gd`、`building_agent.gd` | 精灵取消整图阵营 tint；建筑、死亡、训练和幽灵流程正确 |
| 6：入口回归 | `match_bootstrap.gd`、`ai_vs_ai_bootstrap.gd`、各竞技场/寻路入口及建造调用点 | 创建和重开流程均使用统一默认映射，不遗漏 MatchState 或 team 传递 |

前三阶段可独立准备，资源和加载契约齐备后再接入实体。阶段 6 以检查并修正实际缺口为主，不要求无必要地修改每个入口。

## 10. 验证与验收

以下是实施后的验证计划；本次仅编写文档，未执行这些功能测试。

### 10.1 导出测试

在 `tools/slp_export/tests/` 新增玩家色测试，沿用现有构造小型 SLP 的方式，不要求全部单测依赖本地游戏安装。

- 人工构造同时含 `0x06`、`0x0A`、普通绘制、普通填充、skip、shadow 的帧，验证只有玩家色命令写入的位置随 player 变化。
- 普通绘制即使使用了与玩家色相同的调色板索引，也不能被额外识别为玩家色。
- 校验 1、2 两套图的尺寸、帧数、热点、方向、所有 alpha 一致；非玩家色位置 RGBA 一致。
- 对多层建筑验证完整重合、半透明阴影覆盖和热点偏移，确保每个版本均按原图层规则合成。
- 验证无玩家色素材分类为 `none`；缺失源文件/单个颜色导出失败返回非零，manifest 不发布不完整状态。
- 重跑现有 `test_palette.py`、`test_slp_transparency.py`，防止重新引入黑色透明或阴影丢失问题。

### 10.2 Godot 自动化检查

扩展 `tests/test_sprite_catalog.gd`、`test_match_state.gd`、`test_buildings.gd`、`test_combat_visual.gd`；新增的测试通过 `tests/run_tests.gd` 接入。

- 同兵种红/蓝单位使用不同变体纹理；同兵种同色共享资源包。
- 从行走切到攻击、死亡或村民任一工作动作后仍使用相同 color_id。
- 不同颜色的动画名称、帧数、热点和攻击时机一致。
- 同文明双方不同色；交换文明不交换阵营颜色。
- 新训练单位、新建建筑、竞技场重开保持正确颜色。
- 新变体缺失按约定回退，占位代表色正确，警告不逐帧重复。
- 正常 Billboard 为白色 modulation，幽灵落地后不残留绿色/红色透明 tint。
- 非着色素材共享底图，必要的阵营标记随实体可见性正确显示。

### 10.3 人工画面对照

在 `combat_arena.tscn` 放置两方相同兵种并排截图；分别检查五个原始方向及镜像方向、五种现有单位、村民全部工作动作和死亡动作。在正常对战中检查城镇中心、其他现有建筑、放置预览及出兵；再运行 AI 对战和对决竞技场。

合格标准：旗帜和衣服等可着色区域清楚区分红蓝，皮肤、金属、木材等非玩家色区域一致，无帧错位、镜像错位、阴影缺失或动画中途变色。源素材本身没有玩家色时，独立阵营标记必须能够区分归属。

### 10.4 性能记录

用相同场景、单位数量、镜头和导入设置对比改动前后。记录生成耗时、首次加载耗时、稳定帧耗时、纹理内存和发布包体；分别覆盖一种兵种大量实例和多兵种混合场景。

验收重点是资源不随实例数重复构建、稳定切帧无文件 I/O，以及不存在明显新增卡顿。RGBA8 原始内存可用 `宽 × 高 × 4 × 加载变体数` 粗估；实际结果还受导入压缩、mipmap 和渲染后端影响，PNG 文件大小不能代替显存读数。

## 11. 后续扩展

需要更多预设颜色时，先按相同 manifest 扩展发布颜色集合；不改变实体逻辑。新增任意 RGB 选色、大量调色板，或实测多色纹理内存无法接受时，再评估索引蒙版 Shader。

迁移到 Shader 时继续保持 `team → color_id → visual bundle` 的上层接口，由 SpriteCatalog 更换实现。蒙版必须在 SLP 解码时保留玩家色语义及色阶，不能从导出的 RGB 反推；动画底图与蒙版必须使用相同帧区域和翻转。

多层建筑被半透明阴影覆盖后，最终颜色包含多层贡献，简单的二值蒙版和直接颜色替换可能丢失这种混合。届时需要单独设计合成表示或保留建筑离线变体，并在本项目的 Compatibility 渲染器下验证；不把这一复杂性加入首阶段。
