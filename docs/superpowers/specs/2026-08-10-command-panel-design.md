# AoE2-Style Bottom Command Panel Design

**Date:** 2026-08-10  
**Engine:** Godot 4.7  
**Status:** Approved for planning  

## Goal

为正式局内 UI 增加《帝国时代 2》风格**屏幕底部控制面板**：显示点选单位/建筑信息与血量，并提供建造、训练、停止等指令格；美术来自本地 AoE2 HD interface SLP（离线导出）。

## Decisions Locked

| 项 | 选择 |
|---|---|
| 范围 | 底栏信息区 + 指令区（方案 B）；不做小地图 |
| 外观 | 先固定一套通用底栏条，预留文明皮肤切换（方案 C） |
| 指令 | 迁移建造/训练 + **停止**；攻击仍右键 |
| 实现 | Godot Control 底栏 + 离线导出 UI PNG（方案 1） |
| 顶栏 | 保留现有资源/人口条，不挪到底栏 |
| 多选血量 | 显示首个选中实体血量 + `×N` 数量 |

## Non-Goals

- 小地图 / 真实地图雷达
- 强制攻击、驻守、阵型等完整命令页
- 科技树 UI
- 本期切换中国/条顿两套底栏条（仅预留配置）
- 提交原版 DRS/SLP；仅提交导出 PNG+JSON 与工具改动

## Layout

参考 AoE2 经典分区：

```
┌─────────────────────────────────────────────┐
│ TopBar: food / wood / gold / pop            │  (existing)
├──────────┬──────────────────┬───────────────┤
│ Info     │  Center reserve  │ Command grid  │  (new bottom)
│ name     │  (minimap later) │ ~4×3 / 5×3    │
│ HP bar   │                  │ TextureButtons│
│ ×N count │                  │ + tooltips    │
└──────────┴──────────────────┴───────────────┘
```

- 底栏固定贴视口底部，高度约视口 18–22%
- 左：名称、血条（当前/最大）、多选数量；单选优先显示单位/建筑图标切片
- 中：本期留空或弱装饰（下期小地图）
- 右：指令格

## Selection → Panel Content

| Selection | Info | Commands |
|-----------|------|----------|
| Villager(s) present | First unit HP + count | Existing build set (house, barracks, archery, stable if Teutons, mill, lumber, mining) + **Stop** |
| Military only | First unit HP + count | **Stop** |
| Completed building | Building HP + name | Trainable unit icon buttons + **Stop** (Stop clears orders on selected *units*; buildings with no unit orders: no-op or hide) |
| Mixed | First entity + count | Union of available commands (builds if any villager; Stop always for units) |
| Empty | Cleared | Grid empty / disabled |

### Stop

`UnitAgent.command_stop()`：清除当前 order 与相关目标（MOVE/GATHER/BUILD/ATTACK），回到 idle。对选中的玩家单位批量调用。

### Build / Train

- Build：复用现有 `BuildSystem.begin_placement(BuildingDef)`
- Train：复用建筑训练队列 API（与现 HUD TrainPanel 相同），按钮改为图标格

## Art Export

Offline via `tools/slp_export` from  
`D:/BaiduNetdiskDownload/gaoqingban2/gaoqingban2/resources`  
Palette: `interface/50500.bina`.

| Key | SLP ID | Role |
|-----|--------|------|
| `panel_game` | 51141 | Large game panel strip (shared skin v1) |
| `icons_units` | 50730 | Unit portrait / train icons |
| `icons_buildings` | 50705 (+ 50706–08 if needed) | Build icons |
| `icons_commands` | 50721 | Stop / command icons |

Outputs under `assets/sprites/ui/` (`*.png` + `*.json`). Missing icon → text fallback on the button.

Config hook: `panel_skin` (resource or constants) points at `panel_game` path for future civ variants (`511xx` / HD packs).

## Architecture / Integration

| Piece | Change |
|-------|--------|
| `scenes/ui/hud.tscn` | Add bottom `CommandPanel` regions; retire visible old BuildPanel strip (logic kept) |
| `scripts/ui/hud_controller.gd` | Refresh info + rebuild command grid on `selection_changed` |
| `scripts/entities/unit_agent.gd` | `command_stop()` |
| `scripts/input/selection_controller_2d.gd` | Unchanged signal; consumers expand |
| `tools/slp_export/` | UI priority / `--ui` export list + README |
| `match_bootstrap` | Already wires `hud.setup(..., selection)` |

Data flow:

```
SelectionController.selection_changed
  → HudController refreshes InfoPanel + CommandGrid
  → buttons call BuildSystem / building.train / unit.command_stop
```

## Testing

Headless:

1. Select villager → build command slots present  
2. Select town center → train slots present for civ trainables  
3. `command_stop` clears MOVE order  

Manual:

- Bottom panel pinned; HP updates when damaged  
- Icons clickable; empty selection clears panel  
- Looks recognizably like AoE2 bottom chrome  

## File Touch List (expected)

- `docs/superpowers/specs/2026-08-10-command-panel-design.md` (this file)
- `scenes/ui/hud.tscn`, `scripts/ui/hud_controller.gd`
- `scripts/entities/unit_agent.gd`
- `tools/slp_export/export_sprites.py`, `README.md`, config example
- `assets/sprites/ui/*` (exported)
- `tests/` HUD / stop coverage as needed
