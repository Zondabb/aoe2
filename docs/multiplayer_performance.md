# 联机同步性能

当前 v10 使用[事件驱动静默锁步与紧凑二进制同步](online_fair.md)，并已移除在线观战同步路径。下文保留 v6–v8 的历史实测基线以便对比。

## v10 事件驱动静默锁步 + 二进制优化（2026-11-27）

针对 v6–v9 稳态约 50–100+ kbps 的根本原因（2 倍速下每秒 20 帧必发空 `input_step`、`frame`、`ack` JSON 及 TCP/IP 包头放大），v10 实施了五项优化：

1. **事件驱动静默推进**：开局双方经 `CLOCK_PROBE` / `HEARTBEAT_ACK` / `SYNC_INIT` 对齐单调时钟基准后，无操作、无调速时 **零空帧报文**。仅当存在新指令、溢出拒绝或调度参数变化时，主机才下发 `SCHEDULE`，客机以 10 字节 `SCHEDULE_ACK` 确认（若迟到则由客机暂停并上报 `guest_tick`，主机无损重排，不触发失步）。
2. **紧凑二进制帧（`wire.py` / `wire_codec.gd`）**：局内 8 类高频同步包全部改为小端二进制 WebSocket 帧，移动命令单条仅约 15–22 B（50 单位编队批量包 < 900 B）。
3. **1 Hz 32-bit 摘要心跳**：取消逐帧 `frame` 广播与逐帧 `ack`，改为每现实秒 1 次在整模拟秒（`full_digest`）边界发送 13 字节 `HEARTBEAT` + 13 字节 `HEARTBEAT_ACK`，同时兼作 RTT 采样与失联保护；客机启动校准后每 10 秒补发 1 次防漂移探针。
4. **同种子零关键帧开局**：双端均根据服务下发的 `seed` 本地生成初始地图，开局只需核对 `tick=0` 32-bit 摘要即可直接进入对局，省去开局约 49 KB 的默认地图压缩关键帧突发。
5. **AI 单回合指令自动合批**：`AiGateway` 在每轮 `_apply_response` 执行前后包裹 `NetworkMatch.begin_command_batch()` / `end_command_batch()`，将同一决策周期内的多条 AI 指令合并为单个 `CMD_SUBMIT`。

### 实测对比（中转服稳态出口，2 倍速，双玩家）

| 协议版本 | 稳态消息数/秒（双向） | 中转应用层出向载荷 | 含 TCP/IP+WS 估计（出向） | 开局默认地图关键帧 |
| --- | ---: | ---: | ---: | ---: |
| v6 基线（JSON 逐帧分离） | ~105.3 | 75.8 kbps | ~110+ kbps（含进出约 200 kbps） | ~547 KB（未压缩） |
| v7/v8（JSON 合并帧 + 去重） | ~60–64 | 49.9–54.6 kbps | ~80+ kbps | ~48.7 KB（zlib） |
| **v10（事件驱动静默 + 二进制）** | **2.0** | **0.208–0.209 kbps** | **1.07–1.08 kbps**（计入 TCP ACK 约 **1.91 kbps**） | **0 KB**（同种子同步） |

三组真实双进程 E2E 实测记录（`tools/test_online_fair_e2e.py --traffic-report`）：
- 小地图、零延迟（`.godot/online-fair-e2e-8h__ynk2/traffic-summary.json`）：中转出向载荷 **0.208 kbps**（`13.0 B/s` × 2），TCP/IP+WS **1.072 kbps**（计入 TCP ACK **1.903 kbps**）；2 倍速 **60.43 ticks/s**，时间线 P95 偏差 **29.0 ms**，输入到实际移动 **69.2–69.8 ms**，回退 **0.000 px**。
- 小地图、每方向 25ms + 0–10ms 抖动、交换主机（`.godot/online-fair-e2e-z0eghfqh/traffic-summary.json`）：中转出向载荷 **0.209 kbps**，TCP/IP+WS **1.077 kbps**（计入 TCP ACK **1.913 kbps**）；2 倍速 **59.50–59.66 ticks/s**，P95 偏差 **28.0 ms**，回退 **0.000 px**。
- 默认 480×480 大地图、每方向 25ms + 0–10ms 抖动（`.godot/online-fair-e2e-w887cwtj/traffic-summary.json`）：中转出向载荷 **0.208 kbps**，TCP/IP+WS **1.073 kbps**（计入 TCP ACK **1.906 kbps**）；开局关键帧 **0**，仅 tick 210 故意注入失步后于 tick 252 发送 1 次恢复关键帧（`48,603 B`）；2 倍速 **60.48–60.70 ticks/s**，P95 偏差 **5.0 ms**。

---

## 历史 v6–v8 基线（2026-11-16 ~ 2026-11-17）

- **v8**：新增 `command_batch`、客端 `frame` 去重与 zlib 压缩关键帧（默认地图 547 KB → 48.7 KB），但稳态仍每 50ms 发送 `input_step`、`frame`、`ack`，持续出口仍约 6.6–6.8 KB/s（53–54 kbps）。
- **v7**：合并 `input_frame` + `input_commit` 为 `input_step`，将稳定出口从 v6 的 75.8 kbps 降至 54.6 kbps（降幅 28%）。
- **v6**：公平调度初始版本，双向合计 ~148 kbps JSON + 包头接近 200 kbps。
