# 联机匹配与增量同步

主菜单「联机对战」进入大厅，选择文明、输入昵称后开始匹配。默认服务地址为 `ws://127.0.0.1:8001/ws`，也可通过 `game_settings.cfg` 的 `[multiplayer]` 配置。启动及部署见 [部署文档](multiplayer_deployment.md)和 [Python 服务 README](../multiplayer_service_python/README.md)。

## 协议 v3

服务配对后随机选择一名玩家担任主机，`host_team` 可以是 `0` 或 `1`。队伍编号只决定单位归属；双方收到同一个地图种子和固定模拟参数。游戏与 Python 服务必须一起更新，v1/v2 客户端不能加入 v3 对局。

双方都执行游戏逻辑。玩家操作先交给主机，主机校验单位归属、视野、资源、生产条件及参数，将通过校验的操作按顺序放入帧。主机自己的操作也必须排队，不能提前生效。AI 托管只在主机请求 Python/LLM，产生的操作同样经过帧队列。

- 模拟步长固定为 `1/30` 秒，每个网络帧推进 3 步，目标每秒 10 帧。
- 一帧包含有序操作、结束 `tick` 和 SHA-256 状态校验值；无操作时发送空帧以推进统一时钟。
- 客端执行相同操作和模拟步，校验一致后返回 `ack`。主机收到确认才推进下一帧，网络延迟较高时游戏会减速。
- 增量帧不能合并或丢弃。缺帧、操作重放失败或校验不符时，客端请求全量关键帧修复，然后继续处理增量帧。
- 网络推进使用实际时间，联机模拟不随本机 `Engine.time_scale` 改变。渲染帧率与模拟步数独立。

寻路每步处理固定数量请求，实体按稳定网络 ID 推进；影响移动和战斗的错峰、避让顺序不再依赖进程实例 ID。关键帧包含单位目标、路径、冷却、建筑与训练队列、生产付款、时代/科技研究、箭矢、经济、寻路待办、支援计时和双方迷雾。不会加载消息中指定的脚本或资源路径。

协议 v3 使用整数定点模拟状态：时间单位为 1/30720 秒，每步精确增加 1024；血量、携带量、资源余量和坐标精度为 1/1024。冷却、建造、训练、研究、治疗和弹道推进使用整数运算；采集、治疗和弹道保留除法余数，关键帧同时恢复这些余数。命中距离、部分碰撞、迷雾栅格和墙方向也使用整数计算。界面、存档兼容接口仍可读取秒数和小数值。

当前仍有浮点游戏逻辑：Godot AStarGrid2D 内部寻路、复杂局部避让的速度评分，以及部分接近点计算。单位位置最终写入定点网格，但这不能证明整个模拟跨平台确定。未替换的浮点状态保留原始 64 位数据，避免 JSON 往返改变数值；纯动画帧计数已移出权威状态摘要。v1/v2 客户端不能与本版本混用。

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
python tools/test_incremental_e2e.py --godot "<Godot console executable>"
python tools/test_incremental_e2e.py --godot "<Godot console executable>" --default-map --host-team 1
```

集成测试启动临时回环服务、两个真实游戏进程及晚加入的观众，比较最终状态摘要，并故意扰动客端资源验证修复。`--host-team` 只在测试进程中控制随机选择，生产服务没有此选项。旧的周期快照性能测试属于 v1，当前协议使用上述入口。带宽及取舍见 [性能说明](multiplayer_performance.md)。
