# 原生模拟内核：局部避让、邻居查询与视线检测

实现日期：2026-10-31。适用于单机、联机、地图编辑器试运行和测试场中所有 `UnitAgent` 的移动。

## 1. 为什么改

联机采用锁步：双方每个模拟步都运行同一段游戏逻辑。默认地图每方 60 个单位同时移动时，单个模拟步约 64 ms；上次剖析显示，局部避让、邻居查询和路径点视线检测约占模拟步的七成。机器跟不上每秒 30 步时，整局会一起减速。2 倍速需要每秒 60 步，问题更明显。

这次沿两个方向处理：

1. 把三个热点改写为 C++ GDExtension（`addons/aoe_sim`），只用整数运算，使各平台、各编译器得到逐位相同的结果。
2. 降低重新选方向的频率：求解得到的方向最多沿用 0.25 秒，每步仍检查安全性。

## 2. 改了哪些计算

| 热点 | 原实现 | 现在 |
| --- | --- | --- |
| 局部避让：33 个候选速度的预测评分 | GDScript 浮点运算 | 整数定点算法。原生实现 `AoeUnitField.steer`，GDScript 参考实现 `LocalAvoidance.steer_with_field`，两者结果逐位一致 |
| 邻居查询：附近单位的位置、速度和半径 | 视野空间索引查询，再逐个读取对象属性 | 整数快照 `UnitField`（2 格网格桶），原生实现 `AoeUnitField` |
| 路径点视线检测：两点之间是否有阻挡格 | GDScript 整数采样循环 | 原生实现 `AoeSimKernel.line_clear`，采样点和取整规则不变 |

没有原生库时（Web、macOS，或库加载失败），游戏自动使用 GDScript 实现，结果相同。单位附近有水域岸线时，避让仍由 GDScript 完成，因为岸线检测（`ShoreGeometry`）还是浮点几何；原生求解器只接受轴对齐包围盒。这种情况在每一端都走同一条路径。

### 邻居快照

`VisionService` 持有一个 `UnitField`。单位注册时写入，自己的物理步结束后更新位置和本步速度，死亡时标记失效，注销时移除。其他单位查询到的始终是对方最近一次移动后的状态，与原来直接读取对象属性一致。

查询先按“双方半径 + 预测余量 + 双方速度 × 预测时间”的外界做网格桶和包围盒剔除，再按每个邻居自己的速度计算精确可达距离。超出这个距离的邻居在预测窗口内不可能与任何候选速度接触，剔除后结果不变。

## 3. 整数算法

| 量 | 单位 |
| --- | --- |
| 长度、坐标、半径 | 1/1024 格（与 `SimFixed` 相同） |
| 速度 | 1/1024 格每秒 |
| 时间 | 1/30720 秒（模拟步 1024） |
| 评分 | 65536 = 1.0 |
| 旋转表 | 32768 = 1.0 |

参数与原浮点版本对应：预测窗口 0.9 秒（27648），预测余量 0.12 格（123），上一速度权重 0.18，转向侧偏好 0.08，接触代价从 4.0 线性降到 0，静态前瞻惩罚 2.0。候选仍是原方向、两侧 15° 到 150° 和反向，配合全速、半速与停止，共 33 个。

- 除法统一使用 `Fixed.mul_div`（四舍五入，0.5 远离零）或 `floor_div`；平方根使用逐位整数开方。
- 接触时间由相对运动方程的整数判别式求得，取最早的非负解。
- 输入在两种实现里同样夹紧：速度不超过 8 格/秒，半径不超过 8 格，坐标不超过 16384 格，单步时间不超过 1 秒。所有中间乘积因此都在 64 位有符号整数范围内。
- 风险是对所有邻居求和，与邻居遍历顺序无关，所以哈希桶的迭代顺序不影响结果。
- C++ 代码不使用浮点，避免有符号左移等未定义行为；Windows DLL 静态链接，只依赖系统 C 运行时。

### 确定性如何验证

| 测试 | 检查内容 |
| --- | --- |
| `tests/run_native_sim_equivalence.gd` | 160 个随机场景（含夹紧边界的极端值），比较两种实现的目的地、完整求解缓存和邻居集合；默认地图上 6000 次视线检测 |
| `tests/run_scheduled_avoidance.gd` | 闸口、对向人群和资源点场景，GDScript 与原生实现逐步轨迹完全相同；目标、速度或位置变化会使缓存失效 |
| `tests/run_avoidance_body_pruning.gd` | 邻居剔除前后风险值相同（两种实现） |
| `tests/bench_lockstep_frame.gd` | 整局 129 tick 后完整状态哈希：原生与 GDScript 相同 |
| 双进程联机 | 一端使用原生库、另一端（及晚加入的观众）强制 GDScript：默认地图分别以 0 号和 1 号队伍为主机，最终摘要一致，除人为扰动外无失步；每方 20 名士兵对战 597 tick（约 20 次完整摘要）无失步 |
| `tests/run_lockstep_digest.gd` | 两种实现下均通过：完整摘要覆盖避让缓存等隐藏状态 |

修改任一实现后，必须同步修改另一份并运行等价测试。

## 4. 降低重新选方向的频率

原逻辑：周围有 12 个以上邻居时每 0.1 秒完整求解一次，否则每步都求解。

现在所有单位都最多沿用 0.25 秒。第一次求解后的间隔按网络 ID 分成 6 档错开，避免同一批单位在同一步集中求解。

沿用期间，以下任一条件不满足就立即重新求解：

- 单位到达了上一步预测的位置，目标不变；
- 期望速度的大小变化不超过 1%，方向变化不超过 5°。

满足时，若原路径方向现在已经安全，直接回到原方向；否则沿用上次方向，并按当前速度缩放。沿用的方向还必须：

- 不是停止或接近停止；
- 不越出地图边界，本步和静态前瞻都不撞到建筑或障碍；
- 风险不高于求解时 0.25 以上，也不比直接走原方向高 0.25 以上。

## 5. 行为变化

- 速度经过整数量化，轨迹与旧浮点版本有极小差异。人群移动、静态导航和碰撞测试保持通过。
- 不安全的沿用方向在下一步就会被拒绝；仍然安全的绕行方向最多延续 0.25 秒，然后才转回原方向。
- 静态障碍记录改为整数中心和半尺寸，再按单位半径膨胀，与原包围盒相同。
- 新旧版本的模拟结果不同，不能互相联机。协议版本仍是 3，双方需使用同一版本。

## 6. 性能

2 核云端 Linux 虚拟机，headless，只用于相对比较。

单进程（默认地图，每方 60 个单位同时移动，`bench_lockstep_frame.gd -- 60 40`，取中位数）：

| 项目 | 修改前 | 原生库 | GDScript 回退 |
| --- | --- | --- | --- |
| 单个模拟步 | 63.5 ms | 20.3 ms | 51.3 ms |
| 每网络帧（3 步 + 校验） | 199 ms | 67 ms | 165 ms |
| 48 次完整避让求解（`benchmark_static_navigation.gd`） | — | 0.43 ms | 6.3 ms |

`bench_lockstep_frame.gd` 原先用主机身份给双方下令，另一方的指令因阵营不符被拒绝，实际只有一方在移动；[联机性能说明](multiplayer_performance.md)中 79 ms → 43 ms 的数字就是这样测得的。现在双方各自下令，村民只选本方可见的资源，上表按修正后的基准测得。

双进程对战（`bench_lockstep_e2e.py --army 20 --seconds 15`，默认地图，每方再加 20 名士兵，目标 2 倍速，各测两次）：

| 项目 | 修改前 | 本次 |
| --- | --- | --- |
| 实际速度 | 0.82×～1.04× | 1.28×～1.45× |
| 99% 帧间隔 | 164～220 ms | 131～162 ms |

两个客户端与中转同在一台 2 核机器上，CPU 仍是瓶颈。数字已包含每模拟秒一次的完整状态摘要。

原生模拟步的剩余开销：实体逻辑约 14.2 ms（其中避让求解约 1.4 ms），迷雾栅格约 5.2 ms，视野索引重建约 1.8 ms，寻路与其余约 1.4 ms。

## 7. 构建与发布

`addons/aoe_sim/bin` 已包含预编译库：

| 平台 | 文件 | 编译器 |
| --- | --- | --- |
| Windows x86_64 | `libaoe_sim.windows.template_debug.x86_64.dll`、`...template_release...dll` | llvm-mingw 20261020 |
| Linux x86_64 | `libaoe_sim.linux.template_debug.x86_64.so`、`...template_release...so` | GCC 13 |

编辑器和调试运行使用 `template_debug`，导出版本使用 `template_release`。Windows 导出时 Godot 把 `libaoe_sim.windows.template_release.x86_64.dll` 复制到 `aoe2.exe` 旁边，需随游戏一起发布；发布工作流会检查这个文件。Web 预设排除 `addons/aoe_sim/*`，导出包不登记扩展，浏览器启动时不会报告找不到 wasm 库，模拟使用 GDScript 实现。

重新编译需要 CMake 3.17 以上、git 和支持 C++17 的编译器；找到 Ninja 时自动使用。脚本会把固定版本的 godot-cpp（4.7 API）下载到 `native/godot-cpp`，该目录不提交：

```powershell
# Windows + Visual Studio
python tools/build_native.py
# Windows DLL，使用 llvm-mingw（Windows 或 Linux 主机）
python tools/build_native.py --platform windows --llvm-mingw <llvm-mingw 目录>
# Linux
python tools/build_native.py --platform linux
```

`native/.gdignore` 阻止 Godot 导入源代码和 godot-cpp 自带的测试工程。首次拉取后用编辑器打开一次项目，Godot 会把扩展登记到 `.godot/extension_list.cfg`；headless 运行前可先执行 `--import`。

## 8. 主要文件

| 文件 | 职责 |
| --- | --- |
| `native/aoe_sim/src/avoidance.cpp` | 整数避让求解，逐行对应 `local_avoidance.gd` |
| `native/aoe_sim/src/unit_field.cpp` | `AoeUnitField`：邻居快照、查询和带缓存的求解入口 |
| `native/aoe_sim/src/sim_kernel.cpp` | `AoeSimKernel.line_clear` 视线检测 |
| `native/aoe_sim/src/fixed_math.h` | 与 `SimFixed` 相同的取整除法和整数开方 |
| `scripts/systems/local_avoidance.gd` | GDScript 参考实现与分派 |
| `scripts/systems/unit_field.gd` | GDScript 邻居快照；有原生库时 `create()` 返回 `AoeUnitField` |
| `scripts/systems/vision_service.gd` | 维护单位快照 |
| `scripts/systems/nav_service_holder.gd` | 整数静态障碍查询 `query_static_boxes` |
| `scripts/entities/unit_agent.gd` | 组装运动记录并调用避让 |
| `tools/build_native.py` | 下载 godot-cpp 并编译 |

## 9. 复查

```powershell
Godot_console.exe --headless --path . --import
Godot_console.exe --headless --path . --script res://tests/run_native_sim_equivalence.gd
Godot_console.exe --headless --path . --script res://tests/run_scheduled_avoidance.gd
Godot_console.exe --headless --path . --script res://tests/run_crowd_movement.gd
Godot_console.exe --headless --path . --script res://tests/bench_lockstep_frame.gd -- 60 40
```

没有加载原生库时，等价测试打印 `NATIVE EQUIVALENCE SKIPPED` 后退出；先确认导入已完成，再看其他测试。
