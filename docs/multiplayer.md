# 联机匹配与增量同步

主菜单「联机对战」进入大厅，选择文明、输入昵称后开始匹配。默认服务地址为 `ws://127.0.0.1:8001/ws`，也可通过 `game_settings.cfg` 的 `[multiplayer]` 配置。启动及部署见 [部署文档](multiplayer_deployment.md)和 [Python 服务 README](../multiplayer_service_python/README.md)。

## 协议 v3

服务配对后随机选择一名玩家担任主机，`host_team` 可以是 `0` 或 `1`。队伍编号只决定单位归属；双方收到同一个地图种子和固定模拟参数。游戏与 Python 服务必须一起更新，v1/v2 客户端不能加入 v3 对局。

双方都执行游戏逻辑。玩家操作先交给主机，主机校验单位归属、视野、资源、生产条件及参数，将通过校验的操作按顺序放入帧。主机自己的操作也必须排队，不能提前生效。AI 托管只在主机请求 Python/LLM，产生的操作同样经过帧队列。

- 模拟步长固定为 `1/30` 秒，每个网络帧推进 3 步，目标每秒 10 帧。
- 模拟步在物理帧（30 Hz）中逐步执行，单位移动由物理插值平滑；不再在同一渲染帧里集中执行 3 步和校验。步频 = 实际时间 × 对局速度。对局速度取主机的游戏速度设置（`[game] speed`，默认 `data/game_settings.cfg` 为 2.0，范围 0.25–4），主机每 30 帧在帧内广播一次 `match_speed`，客端和观众据此设置 `Engine.time_scale`，退出对局后恢复本机设置。速度只改变每秒执行多少个固定步，不影响确定性。机器过载时每个渲染帧最多执行 2 × 速度 步，对局整体减速而不是画面长时间卡住。
- 一帧包含有序操作、结束 `tick` 和 SHA-256 状态摘要；无操作时发送空帧以推进统一时钟。摘要覆盖定点位置、血量、命令与目标、计时器、生产队列、经济、时代/科技、寻路待办、支援计时和双方迷雾，直接写入二进制数组计算，不再每帧序列化完整状态 JSON。每个整模拟秒（tick 为 30 的倍数）的帧改用完整摘要，覆盖关键帧中的全部状态，紧凑摘要未包含的隐藏字段也能在 1 秒内发现分歧（见[性能说明](multiplayer_performance.md#紧凑摘要与完整摘要)）。关键帧仍是完整状态。
- 帧是流水线式的：主机不等待上一帧确认，最多领先客端最近确认约 0.6 秒的帧（1 倍速 6 帧，2 倍速 12 帧）；双方同时模拟。只有往返延迟或客端处理落后超过该窗口时，主机才暂停推进、游戏减速。客端校验一致后返回 `ack`，主机按 tick 核对已发布的摘要。
- 客端按到达顺序缓存帧。断流后先攒 1 帧抖动缓冲再继续；等待中的帧超过 2 个时，在每个物理帧的时间预算内多执行几步追赶。观众积压超过 60 帧时改为请求关键帧。对局结束消息到达时，客端先执行完已收到的帧，保证各方最终 tick 一致。
- 增量帧不能合并或丢弃。缺帧、操作重放失败或校验不符时，客端请求全量关键帧修复，然后继续处理增量帧。主机在帧边界（当前帧 3 步完成并发出后）回答关键帧请求。

寻路每步处理固定数量请求，实体按稳定网络 ID 推进；影响移动和战斗的错峰、避让顺序不再依赖进程实例 ID。关键帧包含单位目标、路径、冷却、建筑与训练队列、生产付款、时代/科技研究、箭矢、经济、寻路待办、支援计时和双方迷雾。不会加载消息中指定的脚本或资源路径。

协议 v3 使用整数定点模拟状态：时间单位为 1/30720 秒，每步精确增加 1024；血量、携带量、资源余量和坐标精度为 1/1024。冷却、建造、训练、研究、治疗和弹道推进使用整数运算；采集、治疗和弹道保留除法余数，关键帧同时恢复这些余数。命中距离、部分碰撞、迷雾栅格和墙方向也使用整数计算。界面、存档兼容接口仍可读取秒数和小数值。

当前仍有浮点游戏逻辑：Godot AStarGrid2D 内部寻路、水域岸线检测，以及部分接近点计算。局部避让的速度评分、邻居查询和路径点视线检测已改为整数运算，有原生库的平台由 C++ 扩展计算，其他平台使用逐位相同的 GDScript 实现，见[原生模拟内核](native_simulation.md)。单位位置最终写入定点网格，但这不能证明整个模拟跨平台确定。未替换的浮点状态保留原始 64 位数据，避免 JSON 往返改变数值；纯动画帧计数已移出权威状态摘要。v1/v2 客户端不能与本版本混用。

## 消息格式

端点 `/ws` 使用 UTF-8 JSON 文本帧。下面省略了实际 64 字符校验值和完整关键帧内容；完整字段校验见服务端 `protocol.py`。

```json
{"type":"join_queue","protocol_version":3,"name":"玩家","civ":"chinese"}
{"type":"ready"}
{"type":"command","seq":1,"command":{"op":"move","unit_id":10,"pos":[30,36]}}
{"type":"frame","tick":3,"commands":[{"team":1,"command":{"op":"move","unit_id":10,"pos":[30,36]}}],"checksum":"…"}
{"type":"ack","tick":3,"checksum":"…"}
{"type":"request_keyframe"}
{"type":"keyframe_request","request_id":"服务端生成的请求ID"}
{"type":"keyframe","request_id":"服务端生成的请求ID","tick":3,"state":{"world":{},"simulation":{}},"checksum":"…"}
```

`command.seq` 按玩家独立递增；服务根据连接注入 `team`，玩家不能冒充其他队伍。`frame.tick` 从 3 开始，每次增加 3。只有被选中的主机能发布帧、回答关键帧和提交胜负。服务仅向请求者转发关键帧，不缓存或周期广播全量世界；同一时刻多个请求可共用一份响应。单条操作限 16 KiB、一帧最多 64 条操作/256 KiB、全量消息限 4 MiB。

开始消息 `match_found` 包含 `match_id/team/host_team/players/seed/protocol_version/tick_rate/frame_ticks`。双方 `ready` 后收到 `start`；客端载入初始关键帧并确认后才推进第一帧。`ping/pong`、匹配取消、主动离开及 `match_ended` 保留原有功能。

## 观战和权限

大厅「观看对战」显示已经开局的对局。观众加载场景后发出 `watch_ready` 与关键帧请求，恢复主机当前 tick 的完整状态后执行后续增量帧；详见 [观战文档](spectator.md)。观众不参与玩家确认屏障，退出、慢连接或恢复失败不会结束玩家对局。切换队伍视角或显示全图只影响本地显示，不能下令或开启 AI 托管。

此实现信任随机选出的游戏主机。Python 服务校验消息身份和格式，游戏主机负责规则校验，不具备独立服务器反作弊。所有参与者持有全场状态；迷雾只限制正常界面。请使用相同游戏和 Godot 构建；当前回归覆盖本机 Windows 多进程，没有验证跨架构浮点运算一致性。尚无断线重连或主机迁移。

## 战绩与验证

`http://服务器地址:端口/` 或 `/leaderboard` 提供战绩排行榜。开局后退出/掉线计负，准备阶段中止或无胜者结束不计入；观众不参与排名。SQLite 数据卷及部署设置见服务 README。

当前 v3 回归入口：

```powershell
python -m pytest multiplayer_service_python/tests -q
Godot_console.exe --headless --path . --script res://tests/run_incremental_transport.gd
Godot_console.exe --headless --path . --script res://tests/run_lockstep_state.gd
Godot_console.exe --headless --path . --script res://tests/run_lockstep_combat_frames.gd
python tools/test_incremental_e2e.py --godot "<Godot console executable>"
python tools/test_incremental_e2e.py --godot "<Godot console executable>" --default-map --host-team 1
```

性能探针（见[性能说明](multiplayer_performance.md)）：

```powershell
Godot_console.exe --headless --path . --script res://tests/bench_lockstep_frame.gd -- 60 40
python tools/bench_lockstep_e2e.py --godot "<Godot console executable>" --army 30 --seconds 20
```

集成测试启动临时回环服务、两个真实游戏进程及晚加入的观众，比较最终状态摘要，并故意扰动客端资源验证修复。`--host-team` 只在测试进程中控制随机选择，生产服务没有此选项。旧的周期快照性能测试属于 v1，当前协议使用上述入口。带宽及取舍见 [性能说明](multiplayer_performance.md)。
