# AoE2-style RTS Demo Design（中国 vs 条顿）

**Date:** 2026-08-05  
**Engine:** Godot 4.7  
**Status:** Approved/Implemented  

## Goal

在 Godot 中实现一个**可玩的微型 RTS 对战 demo**：单人 vs AI，仅中国与条顿两个文明，使用本地 AoE2 HD 游戏目录中的美术素材（经离线转换）。胜利条件为摧毁对方城镇中心。

## Decisions Locked

| 项 | 选择 |
|---|---|
| Demo 体量 | 微型对战：经济 + 造兵 + 交战 |
| 引擎 | Godot 4.7 |
| 对战 | 单人 vs 简单 AI |
| 画面 | 3D 场景 + 广告牌精灵 + 斜俯视相机（方案 2） |
| 文明差异 | 外观 + 特色单位 + 少量加成 |
| 资源 | 食物 / 木材 / 黄金（无石头） |
| 现有大象 2D demo | **不保留**；删除相关场景/脚本/资源，主场景改为 3D 对战 |

## Non-Goals

- 时代升级、完整科技树、墙/门、海军、神器、联机
- 解析并 1:1 还原 `empires2.dat` 全量规则
- 将原版游戏整包或未转换 DRS/SLP 提交进公开仓库
- 强 AI / 完整寻路质量对标原作

## Architecture

主战场为 **3D 场景**（`Node3D`），玩法逻辑在 XZ 平面上运行，与渲染分层：

| 层 | 职责 |
|---|---|
| Presentation | 斜俯视 `Camera3D`、地形 Mesh、单位/建筑 `Sprite3D`（billboard）、选中指示、HUD |
| Simulation | 资源、人口、命令、战斗、建造、AI；`_physics_process` 或固定逻辑步进 |
| Input | 屏幕射线与地面求交；屏幕空间框选；右键下达命令 |
| Assets | 离线 SLP/DRS → PNG 精灵表；运行时不读 DRS |
| Civ | 配置表驱动中国 / 条顿起始、特色兵、加成 |

玩家开局选择文明，AI 使用另一文明。

```
Input → Command bus → Simulation entities
                         ↓
                   Presentation sync (transform, anim, UI)
```

各系统边界清晰：采集、建造、战斗、AI 各自读写实体状态，避免 UI 直接改数值逻辑。

## Gameplay Scope

### Win / Lose

- 摧毁敌方**城镇中心** → 玩家胜利（或失败）并显示结算 UI。

### Economy

- 资源：食物、木材、黄金。
- 人口：城镇中心 + 房屋提供人口上限（具体数值实现阶段手调）。
- 开局（地图两端对称）：1 TC、3 村民、附近食物源 / 树 / 金矿；库存足够立即再造村民并开工军事建筑。
- 中国加成体现为开局**额外 1 村民**，以及 TC 造村民略快。

### Buildings（共用）

| 建筑 | 作用 |
|---|---|
| 城镇中心 | 造村民；主要堆积点 |
| 房屋 | 人口 |
| 兵营 | 基础近战兵 |
| 靶场 | 弓箭手；中国连弩兵 |
| 伐木场 / 采矿营 / 磨坊 | 对应资源堆积点（逻辑从简，加成可极弱或仅作 drop-off） |

条顿额外：**马厩**（训练条顿骑士）。中国本 demo **不建马厩**。

条顿建筑血量略高（简化加成）。

### Units

| 单位 | 归属 | 说明 |
|---|---|---|
| 村民 | 共用 | 采集、建造（不做修理） |
| 剑士（单档近战） | 共用 | 兵营 |
| 弓箭手（单档） | 共用 | 靶场 |
| 连弩兵 | 中国 | 靶场；高射速、较低单发伤害 |
| 条顿骑士 | 条顿 | 马厩；高血、高近战甲 |

条顿步兵/骑士近战护甲 +1（落在护甲数值上）。

### Controls

- 左键点选 / 拖拽框选；Shift 加选
- 右键：移动 / 攻击敌人 / 村民采集或前往建造
- 选中建筑：HUD 训练按钮（训练队列长度 1 即可）
- WASD 或方向键平移、屏幕边缘滚屏、滚轮缩放

## 3D Presentation & Simulation

### Scene & Camera

- 平坦（或轻微起伏）地面 Mesh + AoE2 风格地形纹理。
- 单位：`AnimatedSprite3D` / `Sprite3D`，Y-billboard，按移动方向切换朝向帧。
- 建筑与资源点：带占位碰撞的简易几何 + 贴图，或静态精灵。
- 相机：固定俯仰（约 45°–55°），仅平移与缩放；拾取用射线 ∩ 地面平面。

### Commands（FSM）

状态：`Idle | Move | Gather | Build | Attack`。新命令打断当前行为。

- **Move**：XZ 直线移动 + 绕开建筑占位的简易避让（第一版不强制 navmesh）。
- **Gather**：靠近资源 → 定时采集 → 满载回 TC/对应堆积点 → 自动返回。
- **Build**：放置地基 → 村民建造点数 → 完成生成建筑。
- **Attack**：近战进距打击；远程在射程内按冷却结算伤害（可用瞬伤 + 开火动画，子弹可选）。

### Combat

- HP、攻击、冷却、近战甲、远程甲。
- 单位/建筑归零则移除或播极短死亡表现。
- 敌方 TC 归零触发胜负。

### AI（分阶段脚本）

1. **经济**：村民数到阈值；按比例分配食物/木/金。
2. **军事**：造兵营/靶场（条顿再加马厩）；按文明训练特色兵与基础兵。
3. **进攻**：兵力达标或超时后编队推向玩家 TC，途中攻击遇到的敌方单位与建筑。

目标：会发育、会推家、对局可胜可负；不追求高强度微观。

### Data

- `data/civs/` 下中国、条顿配置（费用、HP、攻击、射程、训练时间、加成）。
- 数值手调至「神似」手感，不依赖原版 dat 解析。

## Asset Pipeline

### Source

本地只读：

`D:\BaiduNetdiskDownload\gaoqingban2\gaoqingban2\resources\`

（`_common/drs`、`slp`、`terrain`、`dat` 调色板等。）

### Offline tools

`tools/slp_export/`（Python）：

1. 从 DRS 提取所需 SLP  
2. 用原版 palette 渲染帧为 PNG  
3. 打包精灵表 + 元数据（帧、朝向、锚点）  
4. 地形纹理导入为地面材质  

优先资产：村民、剑士、弓箭手、连弩、条顿骑士、TC/房屋/兵营/靶场/马厩、树、金矿、食物源、基础 UI。

### Repository policy

- 转换后的、demo 必需的小体积 PNG/纹理可进工程。
- 不提交完整原版游戏目录；工具可通过配置路径指向本机安装目录。
- 文档注明：美术版权归原权利方，仅供本机学习/demo。

## Project Layout（拟）

```
aoe2/
  tools/slp_export/
  assets/
    sprites/units|buildings|resources|ui/
    terrain/
  data/civs/
  scenes/
    main_3d.tscn
    ui/hud.tscn
  scripts/
    core/
    entities/
    systems/
    input/
    civ/
  docs/superpowers/specs/
```

### Removal of elephant 2D demo

删除（不再保留作参考入口）包括但不限于：

- `scenes/elephant.tscn`、`scenes/main.tscn`（若仅服务旧 demo）
- `scripts/elephant.gd`、`selection_*.gd`、`main.gd`（旧 2D 主逻辑）
- `assets/elephant_walk.png`、`assets/grass.png`、根目录 `elephant.bmp` 等旧 demo 专用资源
- `project.godot` 中应用名、主场景改为 3D 对战入口

框选/命令的**思路**可在重写 Input 层时复用，但不保留旧 2D 场景与类名耦合。

## Error Handling & Edge Cases

- 资源采尽：节点耗尽后移除或变枯竭，村民自动寻找同类最近资源或 Idle。
- 人口满：训练按钮禁用并提示。
- 放置建筑：与现有占位重叠则拒绝放置。
- AI 或玩家 TC 已毁：停止模拟输入，弹出结算，可返回文明选择。

## Testing（手动验收）

1. 选中国开局：4 村民（3+1）、可采集三资源、可造房屋/兵营/靶场/连弩。  
2. 选条顿开局：建筑更耐打、可造马厩与条顿骑士、近战甲加成可感知。  
3. 框选、移动、攻击、造兵队列正常。  
4. AI 会采集会造兵并进攻；摧毁任一方 TC 正确结算。  
5. 斜俯视相机平移/缩放与点选落点准确。

## Implementation Notes

- 先打通：3D 地面 + 相机 + 选中移动一名村民 → 再叠采集 → 建筑训练 → 战斗 → AI → 文明差异与素材替换占位图。
- 早期可用彩色占位几何验证玩法，再换上转换后的 AoE2 精灵。
