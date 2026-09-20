# Map Editor Design

**Date:** 2026-09-10  
**Engine:** Godot 4.7  
**Status:** Draft — pending review  

## Goal

为 AoE2 RTS demo 增加**可编辑、可复用的地图**能力：在 Godot 内用可视化工具摆放地形障碍、资源、玩家出生点与可选预制建筑，导出为 JSON 地图文件；对战场景通过统一 `MapLoader` 加载，替代各 bootstrap 里硬编码的 `_spawn_*` / `GROUND_MIN` 常量。

**成功标准（Phase 1）：**

- 能编辑并保存一张 ±40 的测试图（含水、悬崖、金矿、树、出生点）
- `pathfinding_arena` 或 `match_2d` 可通过 `map_path` 加载该图
- 加载后 NavGrid / Vision 重建结果与手工摆放等价
- 编辑器内可切换 Nav 网格叠加层验证通行性

## Context（现状）

| 已有 | 缺失 |
|------|------|
| 逻辑坐标 `sim_pos`（Vector2 = xz）+ `IsoMath` 等距显示 | 地图文件格式 |
| `PathBlocker`（水/悬崖/矿块，`path_blockers` 组） | 地图加载器 |
| `ResourceNode`（FOOD/WOOD/GOLD，部分挡路） | 可视化编辑 UI |
| `BuildingAgent` / `UnitAgent` 场景实例 | 出生点 / 阵营区域定义 |
| `NavGridService` + `NavServiceHolder.rebuild_from_scene()` | 编辑器内实时预览 |
| `NavDebugOverlay`（G/N/B/P/V 热键） | 与编辑器的工具栏集成 |
| AoE2 地形精灵：`water_shallow`、`cliff_*`、`grass` | 非程序化地面变体（可选） |
| 各 arena bootstrap 中重复的 `_setup_ground()` | 共享 ground 模块 |

当前地图内容**完全写在代码里**，例如：

- `match_bootstrap.gd`：±60 草地 + 对称基地（TC + 村民 + 三资源）
- `pathfinding_arena_bootstrap.gd`：±36 + 房屋墙 + 金矿 + 水带 + 悬崖
- `combat_arena_bootstrap.gd`：±40 空地 + 军队阵列（`ArenaConfig`）

坐标与寻路规则已在 [pathfinding design](./2026-08-10-pathfinding-design.md) 中锁定：`cell_size = 1.0`，障碍来自 scene groups，单位不参与烘焙。

## Decisions Locked

| 项 | 选择 |
|---|---|
| 地图格式 | **JSON**（`data/maps/*.json`），UTF-8，带 `schema_version` |
| 逻辑坐标 | 全程 **`sim_pos` / Vector2(xz)**，编辑器拾取时用 `IsoMath.screen_to_world` |
| 地面 | Phase 1 沿用 **`grass.png` 平铺**（`GROUND_MIN/MAX/STEP` 写入地图 meta） |
| 障碍实体 | 复用 **`PathBlocker`**、`ResourceNode`、可选 **`BuildingAgent`** 实例化 |
| 寻路预览 | 复用 **`NavDebugOverlay`** + 编辑器内「Rebuild Nav」按钮 |
| 编辑器形态 | **独立 Editor 场景**（`scenes/editor/map_editor.tscn`），非 Godot 官方 TileMap 插件 |
| 运行时加载 | **`MapLoader`**（`RefCounted`）+ bootstrap 薄封装 |
| 首版范围 | 静态摆放 + 出生点；**不含**运行时建造、采空、AI 动态改图 |
| 与 civ 关系 | 地图只定义 **slot**（player/ai/neutral）；文明由 `GameSession` / 开局 UI 决定 |

## Non-Goals（首版不做）

- 完整 AoE2 随机地图生成器（SMX/RMG）
- 高度图 / 多层 TileMap / 地形混合贴图
- 在编辑器中播放完整对战或 AI 决策
- 联机地图同步与 checksum
- 从原版 `.rms` / scenario 文件导入
- 墙体、门、触发器、胜利条件脚本（留 Phase 3+）

---

## Map File Format

### 路径与命名

```
data/maps/
  pathfinding_demo.json
  open_field_40.json
  ladder_1v1.json
```

### 顶层结构

```json
{
  "schema_version": 1,
  "id": "pathfinding_demo",
  "display_name": "Pathfinding Demo",
  "description": "Houses, water band, cliff ridge — ported from pathfinding_arena",
  "bounds": {
    "min": [-36, -36],
    "max": [36, 36]
  },
  "ground": {
    "texture": "res://assets/terrain/grass.png",
    "step": 8,
    "scale": 0.35,
    "fallback_color": [0.20, 0.48, 0.16, 1.0]
  },
  "player_slots": [
    {
      "slot_id": "player",
      "team": "player",
      "spawn": [-40, -40],
      "camera_focus": true,
      "default_base": {
        "town_center": true,
        "villagers": 3,
        "resources": ["food", "wood", "gold"]
      }
    },
    {
      "slot_id": "ai",
      "team": "ai",
      "spawn": [40, 40],
      "default_base": {
        "town_center": true,
        "villagers": 3,
        "resources": ["food", "wood", "gold"]
      }
    }
  ],
  "entities": [
    {
      "type": "path_blocker",
      "id": "water_0",
      "pos": [-16, 14],
      "kind": "water",
      "sheet": "res://assets/sprites/terrain/water_shallow",
      "frame": 0,
      "block_size": [2, 2]
    },
    {
      "type": "resource",
      "id": "gold_a",
      "pos": [-10, 6],
      "resource_type": "gold",
      "amount": 200,
      "gather_rate": 4
    },
    {
      "type": "building",
      "id": "house_a",
      "pos": [0, -2],
      "building_id": "house",
      "team": "player",
      "completed": true
    },
    {
      "type": "unit",
      "id": "scout_1",
      "pos": [-22, -18],
      "unit_id": "villager",
      "team": "player"
    }
  ],
  "tags": ["demo", "pathfinding"]
}
```

### 字段说明

| 字段 | 必填 | 说明 |
|------|------|------|
| `schema_version` | ✓ | 解析器向后兼容版本号 |
| `bounds.min/max` | ✓ | NavGrid 与 `CollisionResolver.set_map_bounds` 范围 |
| `ground` | ✓ | 程序化草地参数（与 bootstrap 常量等价） |
| `player_slots` | 对战图必填；沙盒可空 | 出生点 + 可选默认基地模板 |
| `entities` | ✓ | 静态实体列表（顺序不影响寻路） |
| `entities[].type` | ✓ | `path_blocker` \| `resource` \| `building` \| `unit` |

### `path_blocker` 与现有 `PathBlocker` 对齐

| JSON 字段 | GDScript 属性 |
|-----------|---------------|
| `pos` | `sim_pos` |
| `kind` | `kind`（`water` / `cliff` / `ore` / `block`） |
| `sheet` | `sheet_base` |
| `frame` | `frame_index` |
| `block_size` | `block_size`（省略则 `auto_block_size = true`） |

### `resource` 与 `ResourceNode` 对齐

| `resource_type` | `Enums.ResourceType` | 挡路 |
|-----------------|----------------------|------|
| `food` | FOOD | 否 |
| `wood` | WOOD | 是 |
| `gold` | GOLD | 是 |

### 验证规则（加载 / 保存时）

- `bounds.min < bounds.max`，且 span 建议 ≤ 120（与 NavGrid 性能一致）
- `pos` 在 bounds 内（footprint 允许轻微越界时 warn）
- `sheet` 路径存在（`SpriteCatalog.sheet_paths_exist`）
- `building_id` / `unit_id` 在 `data/buildings` / `data/units` 可解析
- `player_slots` 中 `team` 唯一（1v1）；多 AI slot 留 `schema_version: 2`
- 实体 `id` 在图内唯一

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  scenes/editor/map_editor.tscn                          │
│    MapEditorController                                  │
│    ├─ ToolPalette (place / erase / select / pan)        │
│    ├─ LayerPanel (ground, blockers, resources, spawns)  │
│    ├─ PropertyInspector (selection)                     │
│    └─ MapEditorViewport (Map/Ground + Entities)         │
└──────────────────────────┬──────────────────────────────┘
                           │ save / load
                           ▼
                  data/maps/*.json
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│  MapLoader (scripts/world/map_loader.gd)                │
│    load_json(path) → MapData                            │
│    spawn_into(scene_root, options) → void               │
│    setup_ground(parent) / setup_nav_bounds()            │
└──────────────────────────┬──────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
  match_bootstrap    pathfinding_arena    combat_arena
  (map_path export)  (map_path export)    (optional)
```

### 核心类型（拟）

```gdscript
# scripts/world/map_data.gd
class_name MapData
extends RefCounted

var schema_version: int
var id: StringName
var bounds_min: Vector2
var bounds_max: Vector2
var ground: Dictionary
var player_slots: Array[Dictionary]
var entities: Array[Dictionary]

static func from_dict(d: Dictionary) -> MapData: ...
func to_dict() -> Dictionary: ...
func validate() -> PackedStringArray: ...  # errors/warnings
```

```gdscript
# scripts/world/map_loader.gd
class_name MapLoader
extends RefCounted

static func load_file(path: String) -> MapData: ...
static func save_file(data: MapData, path: String) -> Error: ...

static func spawn_entities(
    data: MapData,
    entities_parent: Node2D,
    match_state: MatchState,
    civ_by_team: Dictionary  # Enums.Team -> CivDef
) -> void: ...

static func setup_ground(data: MapData, ground_parent: Node2D) -> void: ...
```

### Bootstrap 集成（薄改动）

各 bootstrap 增加可选导出变量：

```gdscript
@export var map_path: String = ""  # e.g. res://data/maps/open_field_40.json

func _ready() -> void:
    if map_path.is_empty():
        _setup_ground_legacy()
        _spawn_entities_legacy()
    else:
        var data := MapLoader.load_file(map_path)
        MapLoader.setup_ground(data, ground_node)
        MapLoader.spawn_entities(data, entities, match_state, _civ_map())
    _setup_nav_with_bounds(data.bounds_min.x, data.bounds_max.x)
    ...
```

`player_slots.default_base` 为 true 时，loader 调用现有 `_spawn_base` 等价逻辑，避免重复实现经济开局。

### 与 Nav / Vision 的关系

加载顺序保持不变（与现有 bootstrap 一致）：

1. `setup_ground`
2. `NavServiceHolder.setup(min, max, 1.0)`
3. `spawn entities`（blockers / resources / buildings / units）
4. `call_deferred` → `nav_holder.rebuild_from_scene()` + `vision_holder.rebuild_from_scene()`

编辑器内「Preview Nav」按钮：对当前未保存场景树执行相同 rebuild，驱动已挂载的 `NavDebugOverlay`。

---

## Editor UX

### 场景结构

```
MapEditor (Node2D)
  Bootstrap          # MapEditorController
  Map/
    Ground/
    GridOverlay/     # 可选逻辑格线（1.0 cell）
  Entities/          # y_sort_enabled，与对战场景一致
  Camera2D           # RtsCamera2D 或简化版 pan/zoom
  UILayer/
    Toolbar/
    LayerPanel/
    Inspector/
    StatusBar/       # 坐标、选中 id、验证警告
  NavService         # 编辑模式专用 holder
  NavDebugOverlay    # 默认关闭，按钮开启
```

### 工具

| 工具 | 操作 | 默认层 |
|------|------|--------|
| **Pan** | 中键 / Space 拖拽 | — |
| **Place** | 左键放置当前笔刷 | 当前层 |
| **Erase** | 左键删除命中实体 | 当前层 |
| **Select** | 左键选中；Inspector 改属性 | 任意 |
| **Spawn Slot** | 放置 player/ai 出生点标记 | Spawns |
| **Eyedropper** | 点击复制实体类型 | — |

### 笔刷（Place 模式）

| 类别 | 预设 | 对应实体 |
|------|------|----------|
| Terrain | 浅水、悬崖 A/B | `PathBlocker` + sheet |
| Resource | 浆果、树、金矿 | `ResourceNode` |
| Structure | 房屋、兵营… | `BuildingAgent`（`completed: true`） |
| Unit | 村民、剑士、弓手 | `UnitAgent`（沙盒图） |

笔刷参数：自动对齐 **1.0 sim 格**（可 Toggle 关闭）；`frame` 用滚轮循环。

### 快捷键（建议）

| 键 | 功能 |
|----|------|
| Ctrl+S | 保存 |
| Ctrl+O | 打开 |
| Ctrl+N | 新地图（对话框填 bounds） |
| Ctrl+Z / Ctrl+Y | 撤销 / 重做（Phase 2） |
| G | 切换 NavDebugOverlay（与 arena 一致） |
| 1–4 | 切换工具 |
| Delete | 删除选中 |

### 视觉辅助

- **逻辑格**：半透明 1×1 菱形（`IsoMath`），仅编辑时显示
- **Footprint 预览**：放置前 ghost 显示 `block_size` / resource footprint
- **出生点**：阵营色菱形 + slot 标签
- **越界**：bounds 外红框警告

---

## Implementation Phases

### Phase 1 — 数据层 + 只读加载（≈2–3 天）

- [ ] `MapData` / `MapLoader` + JSON schema v1
- [ ] 单元测试：`load` → spawn → `NavGridService.collect_blockers_from_tree` 数量/范围
- [ ] 手工 JSON：`pathfinding_demo.json`（从 `pathfinding_arena_bootstrap` 迁移）
- [ ] `pathfinding_arena_bootstrap` 支持 `@export var map_path`
- [ ] 共享 `_setup_ground` 抽到 `MapLoader.setup_ground`（bootstraps 去重）

**验收：** 用 JSON 加载的 arena 与硬编码版 Nav 固体格一致（overlay 截图对比）。

### Phase 2 — 可视化编辑器 MVP（≈4–5 天）

- [ ] `scenes/editor/map_editor.tscn` + `MapEditorController`
- [ ] Place / Erase / Select + 3 类笔刷（water/cliff/gold/tree）
- [ ] Save / Load / New
- [ ] Inspector：`pos`、`frame`、`block_size`
- [ ] Rebuild Nav + G 键 overlay
- [ ] 启动入口：`civ_select` 增加「Map Editor」按钮（或 F6 直跑场景）

**验收：** 不手写 JSON 完成一张可玩 pathfinding 图并保存。

### Phase 3 — 对战集成 + 出生点（≈2 天）

- [ ] `player_slots` + `default_base` 模板
- [ ] `match_bootstrap` / `ai_vs_ai_bootstrap` 可选 `map_path`
- [ ] 编辑器 Spawn Slot 工具
- [ ] 加载时校验：至少 2 个 slot、spawn 不落在 solid cell

### Phase 4 — 打磨（可选）

- [ ] 撤销 / 重做命令栈
- [ ] 框选、复制、粘贴
- [ ] 从当前 bootstrap **Export to JSON** 菜单（开发者一次性迁移）
- [ ] 地图列表 UI（`data/maps/index.json` 或扫描目录）
- [ ] `schema_version: 2`：触发器、区域、自定义胜利条件

---

## Testing Strategy

| 层级 | 内容 |
|------|------|
| Unit | `MapData.validate()`、`MapLoader` 读写 round-trip |
| Integration | 加载 `pathfinding_demo.json` → rebuild nav → A* 路径穿过预期缺口 |
| Manual | 编辑器放置水带 → overlay 固体格连续 → 单位无法穿越 |
| Regression | 未指定 `map_path` 时 bootstrap 行为与现版 identical |

测试文件建议：

- `tests/test_map_loader.gd`
- `data/maps/fixtures/minimal_blocker.json`

---

## File Layout（新增）

```
data/maps/
  pathfinding_demo.json
  open_field_40.json
  fixtures/minimal_blocker.json

scripts/world/
  map_data.gd
  map_loader.gd
  map_editor_controller.gd
  map_editor_tools.gd      # Phase 2
  map_editor_brushes.gd    # Phase 2

scenes/editor/
  map_editor.tscn

docs/superpowers/specs/
  2026-09-10-map-editor-design.md   # 本文档
```

---

## Risks & Mitigations

| 风险 | 缓解 |
|------|------|
| JSON 手写易错 | 严格 `validate()` + 编辑器为唯一推荐入口 |
| 大地图 Nav 重建慢 | bounds 上限 warn；编辑器 debounce rebuild（300ms） |
| 与 bootstrap 逻辑分叉 | `MapLoader` 为唯一 spawn 源；legacy 代码仅 fallback |
| 精灵 footprint 与 art 不一致 | 沿用 `SpriteCatalog.pathfinding_footprint_for_sheet`；编辑器 ghost 同算法 |
| 单位/建筑在编辑图内污染对战 | `tags: ["sandbox"]` 地图不被 match 菜单列出 |

---

## Open Questions

1. **地面多样性**：是否在 Phase 2 支持第二套 ground texture（ dirt / sand），还是长期只用 grass？
2. **地图尺寸标准**：默认 80×80（±40）还是对齐 match ±60？建议编辑器 New 对话框提供预设。
3. **Building 未完成态**：编辑器是否允许放置「建造中」建筑用于测试？
4. **版本控制**：JSON 是否格式化 `pos` 为整数（`* 0.5` 格对齐）以减少 diff 噪声？

---

## References

- [Pathfinding System Design](./2026-08-10-pathfinding-design.md)
- [Unit Vision Design](./2026-08-22-unit-vision-design.md)
- `scripts/match/pathfinding_arena_bootstrap.gd` — 障碍摆放参考实现
- `scripts/entities/path_blocker.gd` — 地形障碍实体
- `scripts/presentation/nav_debug_overlay.gd` — 编辑预览叠加层
- `docs/pathfinding_arena.md` — 运行与热键说明
