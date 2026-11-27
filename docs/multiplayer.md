# 联机匹配与增量同步

主菜单「联机对战」进入大厅，选择文明、输入昵称后开始匹配。默认服务地址为 `ws://127.0.0.1:8001/ws`，也可通过 `game_settings.cfg` 的 `[multiplayer]` 配置。启动及部署见 [部署文档](multiplayer_deployment.md)和 [Python 服务 README](../multiplayer_service_python/README.md)。

## 协议 v10

逐消息的字段、二进制帧编码与时序见[联机同步消息详解](multiplayer_sync_messages.md)。

服务配对后随机选择一名玩家担任主机，`host_team` 可以是 `0` 或 `1`。队伍编号决定单位归属；双方收到同一个地图种子和固定模拟参数，按同种子在本地生成初始地图。游戏与 Python 服务必须一起更新，v1–v9 客户端不能加入 v10 对局；本分支已移除在线观战功能。

双方都执行固定步长（`1/30` 秒）游戏逻辑，每 3 步为一个逻辑帧边界。开局客机校准时钟并与主机交换 `SYNC_INIT` 后，双方按对齐的单调时钟各自静默推进：**无玩家操作时双方不发送任何空帧报文**，仅每现实秒由主机在整模拟秒边界发送 1 次 13 字节二进制 `HEARTBEAT` 校验 32-bit 状态摘要，客机回复 13 字节 `HEARTBEAT_ACK`。设计与调优边界见 [对等调度与事件驱动静默锁步](online_fair.md)。每位玩家的游戏在本机直接连接自己的 Python AI 服务，AI 操作与手动输入共用未来帧队列，单回合批量 AI 指令自动合包为 `CMD_SUBMIT`。

- 模拟步长固定为 `1/30` 秒，每个网络帧 3 步；1 倍速每秒 30 ticks，默认 2 倍速每秒 60 ticks。
- 物理帧中按实际墙钟时间 × 对局速度推进，保留普通物理插值；移除本地预测实现，操作按现实时间 100ms 输入预算安排未来执行帧（1 倍速 3 ticks，2 倍速 6 ticks）。
- 仅在有输入、溢出拒绝或调速/预算策略变化时发送紧凑二进制 `SCHEDULE`（最多 62 条公平排序指令），客机以 10 字节 `SCHEDULE_ACK` 确认或无损顺延。
- 摘要计算保留 `LockstepState` 在整模拟秒边界的完整二进制 SHA-256（`full_digest`）；常规心跳携带前 32 位摘要（`checksum32`）核对，失步时客机请求全量压缩关键帧（zlib + Base64）恢复。

## 传输格式

端点 `/ws` 采用 **JSON 文本帧 + 二进制帧** 混合传输：
- **JSON 文本帧**：仅用于匹配与低频控制/恢复（`join_queue`、`cancel_queue`、`ready`、`request_keyframe`、`keyframe`、`finish_match`、`leave`、`ping`/`pong`、`queued`、`queue_cancelled`、`match_found`、`start`、`match_ended`、`error`）。
- **二进制帧**：所有局内高频同步报文（`0x01 CLOCK_PROBE`、`0x02 CLOCK_REPLY`、`0x03 SYNC_INIT`、`0x04 CMD_SUBMIT`、`0x05 SCHEDULE`、`0x06 SCHEDULE_ACK`、`0x07 HEARTBEAT`、`0x08 HEARTBEAT_ACK`），小端编码并做严格边界、有限浮点、规范 varint 和身份校验。

## 战绩与验证

`http://服务器地址:端口/` 或 `/leaderboard` 提供战绩排行榜。开局后退出/掉线计负，准备阶段中止或无胜者结束不计入。SQLite 数据卷及部署设置见服务 README。

```powershell
.\.godot\civ-python\Scripts\python.exe -m pytest -o cache_dir=.godot/pytest_cache multiplayer_service_python/tests -q
Godot_console.exe --headless --path . --script res://tests/run_incremental_transport.gd
Godot_console.exe --headless --path . --script res://tests/run_online_fair.gd
Godot_console.exe --headless --path . --script res://tests/run_lockstep_state.gd
.\.godot\civ-python\Scripts\python.exe tools/test_incremental_e2e.py --godot "<Godot console executable>"
.\.godot\civ-python\Scripts\python.exe tools/test_online_fair_e2e.py --godot "<Godot console executable>" --host-team 0 --traffic-report
```
