# 水域与悬崖

地图编辑器和正式对局现在支持水域、悬崖两类不可通行地形。陆地单位需要沿陆地绕行，村民也不能在这些地形上建造建筑。默认单机地图增加了两片湖泊和两段悬崖。

## 草地细节与缩放

草地使用本机原版 HD 的 `resources/_common/terrain/textures/g_grs_00_color.png`，保持 512×512 原始像素；项目 `assets/terrain/grass.png` 与原图字节相同，SHA256 为 `969cfdc1918d9ee7f49cc1b8e67e2ef99e67c842fae4fa687e5b60821ebc6e4f`。导入工具 `tools/slp_export/import_terrain.py` 现在同时记录和复制草地、水面、浅水、沙滩、岩石五张原版纹理，来源登记在 `assets/terrain/terrain_sources.json`。

旧草地用屏幕坐标采样，并设置 `texture_scale = 0.35`，把每个草纹像素放大约 2.86 倍；继承最近邻过滤，缩小视野时仍容易出现粗颗粒和跳动。现在由 `TerrainVisual.setup_grass()` 创建单个地面多边形，四个顶点使用世界坐标 UV，草纹沿等距地面方向展开，地图尺寸或分块不影响密度和相位。

`GRASS_TEXTURE_PIXELS_PER_SIM = 20.0` 以当前原版精灵共同的 1.2 倍显示比例为基准，使草纹颗粒接近原版地面与人物的像素比例。显示密度参考本地 openage 的重建资料：约 96×48 像素原版格、512 像素草图和 10×10 格循环，再适配当前精灵比例。地面几何使用现有 2:1 等距投影和地图边界。

草地单独启用 mipmap 与 `TEXTURE_FILTER_LINEAR_WITH_MIPMAPS`。近景保留纹理细节，远景混合合适的缩小层级，降低颗粒闪烁；单位、建筑的精灵采样保持原有设置。正式地图、地图编辑器、AI 对战、战斗和寻路测试场景共用同一地面绘制入口，原来的重复 Sprite 草块网格改为一张连续地面。

实际图形验证：

```powershell
$godot = "D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
& $godot --path . --rendering-method gl_compatibility --script tests/render_grass_detail.gd
```

测试需真实图形后端，不使用 `--headless`；可用隐藏窗口运行。检查原尺寸、实际最小缩放 0.45 和更远的 0.2，输出 `.godot/grass-detail-current-zoom-100.png`、`-045.png`、`-020.png`。验证草地仍有细节、缩小时高频噪声降低、整个地图与相邻分块显示一致；分块仅有最大 1/255 色值的插值舍入差异，没有超过 2/255 的可见差异。单张地面不随地图面积增加节点数。

2026-10-12 验证共 334 项通过：实际草地渲染 30 项、五个测试场景地面及竞技场回归 48 项、地形 151 项、地图编辑器 105 项。相同摄像机 0.45 缩放、相同建筑和人物参照下，草地相邻像素亮度差从 0.04938 降到 0.01302，约减少 74%；在更远的 0.2 缩放下，降到 0.00848。对照图为 `.godot/grass-detail-baseline-zoom-045.png` 和 `.godot/grass-detail-current-zoom-045.png`。

过滤和 UV 行为参考 [Godot Polygon2D 文档](https://docs.godotengine.org/en/stable/classes/class_polygon2d.html)与 [CanvasItem 纹理采样文档](https://docs.godotengine.org/en/stable/classes/class_canvasitem.html)。

## 原版沙滩与自然岸线

水域现在将相连、重叠的编辑范围合并，再生成不规则岸线。岸缘按水面、浅水、浅白沙滩、草地的顺序渐变，消除水面直接贴着草地的硬边。岸线起伏和纹理采样使用确定的世界坐标，相同地图在编辑器、正式对局、存档恢复与联机客户端中呈现相同的轮廓。移动摄像机、缩放视野和重建绘制节点不会改变岸线。

沙滩使用本机原版 HD 的 `resources/_common/terrain/textures/g_bc3_00_color.png`，即扩展资料片 DAT 中地形 `53` **Beach 4**；浅水使用 `g_sh2_00_color.png`，即地形 `59` **Shallows**。两张图都是原版 `512 × 512` PNG 的原样复制，没有重新绘制、染色或放大像素。源地形名字和编号来自完整读取的 `resources/_common/dat/empires2_x2_p1.dat`（`VER 5.7`）。`g_snd` 在这个 DAT 中是 **Snow Dirt**，并不是沙滩。

| 项目贴图 | 原版地形 | SHA256 |
| --- | --- | --- |
| `assets/terrain/beach.png` | `53 / Beach 4 / g_bc3` | `e023c6d75361b3e45d2902ffda4468827964b5b9da71effd2bf8e85aa7cdd601` |
| `assets/terrain/shallow.png` | `59 / Shallows / g_sh2` | `44d03695d8e8d9edcd460f0aef1e6eb85b74e73708a3a640ddc5cfe01154741a` |

水面、浅水、沙滩与草地使用相同的世界相位及每游戏格 `20` 个贴图像素的密度，缩小视野时启用 mipmap 与线性过滤，保持细节比例一致。导入工具 [import_terrain.py](../tools/slp_export/import_terrain.py) 可重新复制这些素材；[terrain_sources.json](../assets/terrain/terrain_sources.json) 保存原图路径、SHA256、原版地形编号和 DAT SHA256，方便核对来源。

地图的 `pos`、`block_size`、边界校验和选择框仍使用作者设置的矩形范围。寻路使用实际的不规则水面轮廓，沙滩可以行走；绘制与阻挡共享同一条岸线。现有地图、存档和联机快照继续保存作者设置的地形位置与尺寸。

## 在地图编辑器中使用

1. 在主菜单打开 **地图编辑器**，选择 **连续放置**，或按 `2`。
2. 类别选择 **地形（水体 / 悬崖）**，再选择 **水域**或**悬崖**。
3. 在 **地形画笔尺寸**设置宽、高。两项分别允许 `1–128` 游戏格，步长为 `1`；水域默认 `16 × 12`，悬崖默认 `16 × 4`。
4. 在地图上单击放置一块地形。连续放置并连接、重叠多个地形块，可组成湖泊、河道和较长的悬崖。
5. 按 `1` 选择地形，可拖动位置；也可修改 **X / Z**、**地形宽（格）/ 地形高（格）**后点击 **应用对象属性**。删除、撤销和重做与普通地图对象相同。

这里的宽、高是地面的两个逻辑方向，不是屏幕像素。在等距视角下，逻辑编辑范围显示为平行四边形，水面在这个范围内呈现自然岸线。地形的完整占地必须位于地图边界内；地形块之间允许重叠，建筑、单位和资源不能放在实际水面或悬崖内，沙滩可放置陆地对象。

按 `P` **试运行**，选择村民或军队，右键点击障碍另一侧的陆地，可检查绕行路线。试运行结束后恢复地图初始状态。

按 `Ctrl+S` 保存为格式化 JSON，再按 `Ctrl+O` 可重新打开。正式对局从 **单机游戏**选择该地图：`user://maps` 中的文件自动进入地图列表，其他目录的地图使用 **导入地图…**选择，然后设置文明并点击 **开始游戏**。地形位置、类型和尺寸均从文件加载。详见[地图编辑器说明](map_editor.md)及[主菜单说明](main_menu.md)。

## 默认单机地图

默认地图仍为 `480 × 480` 游戏格，即 `120 × 120` 原版地形格，保留原来的营地与 1070 个资源对象。新地形绕地图中心旋转 180° 对称分布：

| 地形 | 中心位置 `[x, z]` | 完整占地 `[宽, 高]` |
| --- | --- | --- |
| 湖泊一 | `[-80, 90]` | `[64, 44]` |
| 湖泊二 | `[80, -90]` | `[64, 44]` |
| 悬崖一 | `[-15, 100]` | `[12, 72]` |
| 悬崖二 | `[15, -100]` | `[12, 72]` |

两个起始营地、主资源工作带和地图中部留有陆地通路。两方获得相同的障碍数量和占地，既有资源群不被水域或悬崖覆盖。保存的自定义地图始终使用文件内的地形，不自动添加默认地形。默认地图的更多信息见[默认地图说明](default_map.md)。

## JSON 格式

新增地形仍使用 `aoe2-rts-map / 1`。以下是一张 `96 × 80` 地图的有效格式示例，包含两方营地、村民、一片水域和一段悬崖；实际制作对战地图时还应添加足够的资源。

```json
{
  "format": "aoe2-rts-map",
  "schema_version": 1,
  "display_name": "水域与悬崖示例",
  "bounds": {
    "min": [-48, -40],
    "max": [48, 40]
  },
  "entities": [
    {
      "id": "player_town_center",
      "type": "building",
      "building_id": "town_center",
      "team": "player",
      "pos": [-30, -24]
    },
    {
      "id": "player_villager",
      "type": "unit",
      "unit_id": "villager",
      "team": "player",
      "pos": [-24, -24]
    },
    {
      "id": "ai_town_center",
      "type": "building",
      "building_id": "town_center",
      "team": "ai",
      "pos": [30, 24]
    },
    {
      "id": "ai_villager",
      "type": "unit",
      "unit_id": "villager",
      "team": "ai",
      "pos": [24, 24]
    },
    {
      "id": "lake",
      "type": "terrain",
      "terrain_id": "water",
      "pos": [-12, 8],
      "block_size": [16, 12]
    },
    {
      "id": "cliff",
      "type": "terrain",
      "terrain_id": "cliff",
      "pos": [14, -8],
      "block_size": [16, 4]
    }
  ]
}
```

地形记录中的 `terrain_id` 为 `water` 或 `cliff`，`pos` 是占地中心，`block_size` 是完整宽、高；地形没有所属阵营，不需要 `team`。文件校验要求尺寸是有限正数且每项不超过 `128`，编辑器画笔使用 `1–128` 的整数尺寸。加载前统一检查未知类型、重复 ID、无效尺寸、越界以及不可通行地形与陆地对象重叠；无效文件不会替换当前地图。旧版草地地图无需添加地形字段，仍可加载。

## 实现原理

**保存与生成。** [MapData](../scripts/world/map_data.gd) 和 [MapCatalog](../scripts/world/map_catalog.gd) 定义、校验中立地形记录；[MapLoader](../scripts/world/map_loader.gd) 将每个记录实例化为一个 [PathBlocker](../scripts/entities/path_blocker.gd)，并设置 `auto_block_size = false`，直接使用文件尺寸。不会根据贴图大小重新估算地形占地。默认生成器写入相同的记录，因此编辑器、自定义地图、默认对局和联机加载采用一致的数据。

**寻路与碰撞。** 每块地形加入 `path_blockers` 和 `terrain_regions`，作者设置的逻辑半占地为 `block_size / 2`。水域将相连、重叠的范围合并后生成实际不规则水面多边形；导航、路径简化、局部碰撞与绘制使用同一岸线，沙滩属于可通行陆地。悬崖保持矩形阻挡。导航结合单位自身半径留出边界，单位可以绕过地形，有障碍的路径不能直接穿过水域或悬崖。大型区域通过静态空间索引供附近单位查询。建筑合法性检查也读取这些地形，玩家和 AI 都不能把地基放在障碍上。

**建筑出口。** 训练完成后，建筑检查周边候选位置的陆地通行、单位半径、静态碰撞和其他单位占用，并检查从建筑到出口的整个线段，避免隔着水域生成单位。没有有效出口时，进度保留在 `100%`，已付资源和人口预约保持不变，每 `0.25` 秒重新尝试；出口恢复后正常出兵，也可以取消训练。

**联机更新。** 快照同步地形类型、中心和尺寸。更新已有地形时替换绘制表面、选框和世界 UV，并通知该对局的导航管理器刷新静态碰撞索引和路径。重复快照复用相同外观与导航缓存；非法尺寸、类型或越界占地会在修改场景前被拒绝。默认完整地图加上四块地形仍在现有 `512 KiB` 消息限制内。

**单机存档。** 完整对局存档保存当前地形及其迷雾记忆，读取后重建寻路阻挡，并保留多边形纹理、UV、绘制层级和悬崖迷雾材质。水域记忆保存当时观察到的岸线边、沙滩宽度及浅水、沙滩和草地原版贴图引用；仅保存实际使用的边，读取后恢复着色器数组。迷雾纹理、当前观察阵营及屏幕原点由当前对局重新绑定，不写入存档。已隐藏且消失的地形只恢复视觉记忆，不生成阻挡；小地图继续按探索区域裁剪。建筑等待出口的重试状态也会保存，旧存档没有该字段时使用默认值。地图编辑器 JSON 与完整对局存档是两种文件，后者使用单机存档界面，见[单机存档说明](single_player_saves.md)。

**显示。** [TerrainVisual](../scripts/presentation/terrain_visual.gd) 将编辑范围的四个角投影到等距地面。水域使用地面 `Polygon2D` 和岸线着色器，在范围内混合水面、浅水、沙滩与草地。纹理及岸线起伏都锚定世界坐标，放大湖泊也不会放大水纹。水面处于 `z = -49`，在 `z = -50` 的地面迷雾层之上，由岸线着色器逐像素处理迷雾，避免记忆重复变暗。悬崖使用岩石顶面和两片前方立面，表现 `36` 像素的高差，顶面处于 `z = -99`；立面下沿落在实际阻挡边界，岩壁参与单位遮挡。每区域只需要一个模拟节点及少量绘制表面，区域面积扩大不会增加成千上万个地形节点。

草地、水纹、浅水、沙滩和岩石顶面直接来自本机《帝国时代 II HD》地形 PNG；岩壁纹理取自原版 `226.slp` 的有效岩面像素。导入工具是 [import_terrain.py](../tools/slp_export/import_terrain.py)，源路径和导入记录见 [terrain_sources.json](../assets/terrain/terrain_sources.json)。

**战争迷雾与遮挡。** 地形作为静态障碍纳入迷雾可见性和记忆。[FogMemory](../scripts/presentation/fog_memory.gd) 保留 `Polygon2D` 的形状、纹理、UV、颜色和绘制层级，已探索但离开视野的区域显示记忆外观。前景岩壁使用 [terrain_cliff_fog.gdshader](../shaders/terrain_cliff_fog.gdshader)，逐片元采样当前对局的迷雾数据：未探索部分裁剪，已探索但当前不可见部分变暗。看到长悬崖的一端不会显示另一端的未知岩壁；记忆材质也沿用该裁剪，并避免重复施加记忆暗色。切换观战视角时重新绑定同一份迷雾纹理。[UnitOcclusion](../scripts/presentation/unit_occlusion.gd) 支持多边形岩壁，并按真实纹理与深度生成遮挡轮廓，避免把平坦水面当作屋顶遮住单位。

## 验证与运行命令

在项目目录的 PowerShell 中先设置本机可执行文件路径；前面的 `&` 是 PowerShell 调用符：

```powershell
$godot = "D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
$env:APPDATA = Join-Path (Get-Location) ".godot/terrain-tests-profile"

& $godot --headless --path . --script tests/run_terrain.gd
& $godot --headless --path . --script tests/run_shore_geometry.gd
& $godot --headless --path . --script tests/run_terrain_editor.gd
& $godot --headless --path . --script tests/run_terrain_spawn.gd
& $godot --headless --path . --script tests/run_terrain_save.gd
& $godot --headless --path . --script tests/run_terrain_network_minimap.gd
& $godot --headless --path . --script tests/run_default_map.gd
& $godot --headless --path . --script tests/run_static_navigation.gd
& $godot --headless --path . --script tests/run_crowd_movement.gd

& $godot --path . --rendering-method gl_compatibility --script tests/render_terrain.gd
& $godot --path . --rendering-method gl_compatibility --script tests/render_shoreline.gd
& $godot --path . --rendering-method gl_compatibility --script tests/run_terrain_save.gd -- --render
& $godot --path . --rendering-method gl_compatibility --script tests/render_terrain_occlusion.gd
& $godot --path . --rendering-method gl_compatibility --script tests/render_terrain_minimap.gd
```

编辑器专项检查地形画笔、位置与尺寸修改、撤销重做、地图保存加载及试运行。默认地图检查对称地形和陆地通路；导航、群体移动检查阻挡与绕行；联机与小地图专项检查地形同步和迷雾保护。实际 OpenGL 检查水体拼接、真实范围、岩壁轮廓及迷雾记忆像素，并通过真实迷雾管理器验证长悬崖的未知部分不泄露、记忆暗色不重复及视角切换。

图形测试需要顺序运行。`render_terrain.gd` 输出 `.godot/terrain-water.png`、`.godot/terrain-cliff.png`、`.godot/terrain-cliff-unit.png`，以及 `.godot/terrain-cliff-fog-visible.png`、`.godot/terrain-cliff-fog-memory.png`；日志和截图是验证产物，不属于地图文件。

`render_terrain_minimap.gd` 输出 `.godot/terrain-minimap-preview.png`，检查矩形小地图的真实绘制、部分探索的湖泊、已探索变暗及菜单地图预览。上述 `APPDATA` 设置让测试使用独立存档目录，关闭该 PowerShell 后恢复通常环境。

本轮地形专项共 **425 项检查通过，0 失败**：地图与阻挡 `151`、编辑器 `59`、联机与小地图 `50`、训练出口 `51`、实际地形渲染 `57`、多边形遮挡 `47`、实际小地图渲染 `10`。默认地图 `2742`、静态导航 `3831`、原地图编辑器 `105`、群体移动 `95`、自动续采 `88`、迷雾 `73`、迷雾缓存 `30`、原小地图 `49`、AI 建筑间距 `98` 和时代升级 `615` 项回归也通过；生产队列与联机运行回归无失败。图形测试使用实际 OpenGL 渲染，并通过旧单位遮挡的 `69` 项检查。

合并单机存档和性能缓存后，地形存档专项新增 `39` 项检查通过；实际 OpenGL 加上保存恢复前后画面一致性检查，共 `40` 项通过。小地图同时保留静态标记缓存和地形迷雾裁剪，缓存回归 `47` 项通过。上述 `425` 项为初次地形实现的验证记录。

## 当前范围

水域和悬崖保持作者设置的矩形编辑与选择范围，水域按实际不规则水面阻挡，岸边沙滩可以行走。水面显示具有自然起伏的岸线、浅水和沙滩过渡。尚未提供海军、水上寻路、桥梁、高地坡道和高度带来的战斗加成；悬崖顶面也是不可到达区域。地形块可连接或重叠，悬崖内部立面尚未自动合并。地图保存记录初始地形，不记录对局中的单位位置与游戏进度。
