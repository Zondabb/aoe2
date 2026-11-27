# 联机对等调度与事件驱动静默锁步（协议 v10）

`online_fair` 保留玩家主机和轻量 Python 中转。双方均在本地通过同一地图种子或地图数据确定性生成世界，主客双方按对齐后的单调时钟各自推进固定步长（`1/30` 秒）模拟；云端不运行 Godot，不计算寻路、经济、战斗或 LLM。仅在有玩家操作或调度参数变化时才交换紧凑二进制包，空帧零网络报文；本分支已移除在线观战同步路径。

## 指令与静默时间线生命周期

1. **同种子零关键帧开局**：双方 `ready` 后，服务下发 `start`（含一致的 `seed`、`host_team`、`tick_rate=30`、`frame_ticks=3`）。双方各自生成实体并计算 `tick=0` 摘要。客机发 `0x01` `CLOCK_PROBE`（13 字节）校准时钟偏移与 RTT，随后发 `0x08` `HEARTBEAT_ACK`（13 字节，附 32-bit 摘要与 `echo_usec32=0`）；主机核对摘要一致后回发 `0x03` `SYNC_INIT`（26 字节，含共同起点 `epoch_usec`、倍速与输入预算），直接开局而无需传输约 49 KB 的初始关键帧。仅当初始摘要不符或自定义差异时才回退到压缩关键帧。
2. **玩家输入提交（`0x04` `CMD_SUBMIT`）**：玩家操作分配本队递增 `seq`，输入预算按现实时间 100ms 换算并向上对齐到 3-tick 网络帧（1 倍速 3 ticks，2 倍速 6 ticks，最多 180 ticks）。主机本机操作直接进入 `pending`（并对浮点坐标做 32-bit wire 规范化保证确定性）；客机操作通过二进制 `CMD_SUBMIT` 发往主机（1～64 条批量，单条移动仅约 15–22 字节），由 Python 中转校验顺序并覆盖写入真实 `team`。玩家在本机连接自己的 Python AI 服务；AI 单回合下发的多条指令通过 `begin_command_batch()` / `end_command_batch()` 合并为单个 `CMD_SUBMIT`。
3. **两阶段日程确认（`0x05` `SCHEDULE` / `0x06` `SCHEDULE_ACK`）**：
   - 无新指令、无溢出拒绝且调度参数未变时，主机和客机按 `SYNC_INIT` 约定的 `epoch_usec` 与倍速各自静默推进，**不发送任何空帧报文**。
   - 当存在待执行指令或参数变化时，主机发出一条紧凑二进制 `SCHEDULE`（含 `schedule_id`、`tick`、`epoch_usec`、按队伍公平交替排序且最多 62 条指令、可选溢出 `rejected` 与变化时的 `timing`）。主机在尚未收到 `SCHEDULE_ACK` 前于 `tick` 边界短暂等待，不会自行提前跑过未确认日程。
   - 若客机尚未执行到 `schedule.tick`，接收 `SCHEDULE` 并回复 `SCHEDULE_ACK(accepted=1)`（10 字节）；若 `SCHEDULE` 迟到且客机已进入或越过 `schedule.tick`，客机在当前帧边界暂停于 `guest_tick` 并回复 `SCHEDULE_ACK(accepted=0, guest_tick)`，主机将指令无损顺延至 `guest_tick + 3` 后重新下发 `SCHEDULE`，**不触发失步与全量关键帧重传**。
4. **1 Hz 心跳与全量摘要核对（`0x07` `HEARTBEAT` / `0x08` `HEARTBEAT_ACK`）**：
   - 主机每现实秒在整模拟秒边界（`tick % 30 == 0`，即 `LockstepState.full_digest` 边界；1 倍速每 30 ticks、2 倍速每 60 ticks）发送 1 次 13 字节二进制 `HEARTBEAT`（含 `tick`、`checksum32`、`sent_usec32`）。
   - 客机核对同 tick 的 `checksum32` 后回复 13 字节 `HEARTBEAT_ACK`。主机据此更新 RTT 与最长 3.0 秒失联保护租约；客机仅保留启动后每 10 秒 1 次 `CLOCK_PROBE` 防晶振漂移。
5. **关键帧恢复与终局对齐**：若 `HEARTBEAT` 摘要不一致，客机发送 JSON `request_keyframe`，主机将未执行的未来日程指令退回 `pending`、暂停推进并在帧边界返回 zlib+Base64 压缩关键帧，客机恢复后发 `HEARTBEAT_ACK(echo=0)` 重新对齐时间线。终局 `finish_match` 携带主机最终 `tick`，客机 `drain(final_tick)` 推进至完全一致的结束帧。

## 验证

```powershell
.\.godot\civ-python\Scripts\python.exe -m pytest -o cache_dir=.godot/pytest_cache multiplayer_service_python/tests -q
Godot_console.exe --headless --path . --script res://tests/run_online_fair.gd
Godot_console.exe --headless --path . --script res://tests/run_incremental_transport.gd
Godot_console.exe --headless --path . --script res://tests/run_lockstep_state.gd
.\.godot\civ-python\Scripts\python.exe tools/test_online_fair_e2e.py --godot "<Godot console executable>" --host-team 0 --delay-ms 0 --jitter-ms 0 --max-input-ms 250 --traffic-report
.\.godot\civ-python\Scripts\python.exe tools/test_online_fair_e2e.py --godot "<Godot console executable>" --host-team 1 --traffic-report
.\.godot\civ-python\Scripts\python.exe tools/test_online_fair_e2e.py --godot "<Godot console executable>" --host-team 0 --default-map --max-final-window-ms 100 --traffic-report
```

实测三组真实双进程测试（含零延迟、25ms+10ms 人工抖动交换主机、默认 480×480 大地图与强制失步恢复）：
- 中转稳态出向应用层载荷：**0.208–0.209 kbps**（双端合计 2 条 13B 消息/秒），含 TCP/IP+WebSocket 包头约 **1.07–1.08 kbps**（计入 TCP ACK 估测约 **1.90–1.91 kbps**）。
- 开局关键帧数：**0**；仅在 tick 210 注入失步后触发 1 次关键帧恢复。
- 2 倍速稳态推进速度：**59.50–60.70 ticks/s**（设定速度的 99.2%–101.2%），时间线 P95 偏差 **5.0–29.0 ms**，直线移动回退 **0.000 px**。

实现入口：`scripts/network/wire_codec.gd`、`scripts/network/fair_lockstep.gd`、`scripts/network/network_match.gd`、`scripts/network/network_session.gd`、`multiplayer_service_python/wire.py`、`multiplayer_service_python/matchmaking.py`。
