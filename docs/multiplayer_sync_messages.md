# 联机同步消息详解（online_fair，协议 v10）

玩家通过 WebSocket 的 `/ws` 与 Python 中转服务通信：匹配与关键帧恢复使用 **JSON 文本帧**，局内对时、开局同步、玩家指令、日程调度和 1 Hz 心跳全部使用 **小端二进制帧**。本分支已移除在线观战同步。

## 1. JSON 控制消息（文本帧）

```jsonl
{"type":"join_queue","protocol_version":10,"name":"小林","civ":"teutons"}
{"type":"queued"}
{"type":"match_found","match_id":"M","team":1,"players":[{"team":0,"name":"阿青","civ":"chinese"},{"team":1,"name":"小林","civ":"teutons"}],"protocol_version":10,"host_team":0,"seed":12345,"tick_rate":30,"frame_ticks":3}
{"type":"ready"}
{"type":"start","match_id":"M","protocol_version":10,"host_team":0,"seed":12345,"tick_rate":30,"frame_ticks":3}
{"type":"finish_match","winner":1,"tick":468}
{"type":"match_ended","match_id":"M","winner":1,"reason":"completed","tick":468}
```

排队取消与心跳：
```jsonl
{"type":"cancel_queue"}
{"type":"queue_cancelled"}
{"type":"ping"}
{"type":"pong"}
```

失步恢复关键帧（仅异常/不匹配时触发，正常同种子开局不发送）：
```jsonl
{"type":"request_keyframe"}
{"type":"keyframe_request","request_id":"R"}
{"type":"keyframe","request_id":"R","tick":240,"checksum":"64位十六进制SHA-256","codec":"zlib","raw_size":232740,"data":"<Base64>"}
```

## 2. 二进制帧格式（Byte 0 = `pkt_type: u8`）

| `pkt_type` | 名称 | 方向 | 固定/典型长度 | 载荷布局（小端） |
| --- | --- | --- | ---: | --- |
| `0x01` | `CLOCK_PROBE` | 双方 ↔ 中转 | 13 B | `u8(0x01) \| u32 nonce \| u64 sent_usec` |
| `0x02` | `CLOCK_REPLY` | 双方 ↔ 中转 | 21 B | `u8(0x02) \| u32 nonce \| u64 sent_usec \| u64 received_usec` |
| `0x03` | `SYNC_INIT` | 主机 → 客机 | 26 B | `u8(0x03) \| u32 tick \| u64 epoch_usec \| u16 speed_milli \| u8 input_delay_ticks \| u32 delay_from_tick \| u32 checksum32` |
| `0x04` | `CMD_SUBMIT` | 玩家 → 主机 | 14–28 B（单指令） | `u8(0x04) \| u8 team(中转覆写) \| varint seq \| u32 source_tick \| u32 execute_tick \| u8 count(1..64) \| commands[]` |
| `0x05` | `SCHEDULE` | 主机 → 客机 | ~28 B+（仅非空） | `u8(0x05) \| u32 schedule_id \| u32 tick \| u64 epoch_usec \| u8 flags \| u8 cmd_count \| [timing] \| commands[] \| [rejected[]]` |
| `0x06` | `SCHEDULE_ACK` | 客机 → 主机 | 10 B | `u8(0x06) \| u32 schedule_id \| u8 accepted(0\|1) \| u32 guest_tick` |
| `0x07` | `HEARTBEAT` | 主机 → 客机 | 13 B | `u8(0x07) \| u32 tick \| u32 checksum32 \| u32 sent_usec32` |
| `0x08` | `HEARTBEAT_ACK` | 客机 → 主机 | 13 B | `u8(0x08) \| u32 ack_tick \| u32 checksum32 \| u32 echo_usec32` |

### 命令编码（`op_byte = op_id | (flags << 5)`）

- `0x01 move`：`varint unit_id`, `f32 x`, `f32 y`（`flags==1` 时附加 `f32 formation_speed`）
- `0x02 stop`：`varint unit_id`
- `0x03 gather` / `0x05 attack`：`varint unit_id`, `varint target_id`
- `0x04 build`：`varint unit_id`, `varint building_id`
- `0x06 train`：`varint building_id`, `str8 unit_def_id`
- `0x07 cancel_train`：`varint building_id`, `varint queue_id`
- `0x08 place_building`：`varint builder_id`, `str8 building_def_id`, `f32 x`, `f32 y`（`flags & 4` 时 `orientation = flags & 3`）
- `0x09 research_age` / `0x0A cancel_research_age`：`varint building_id`
- `0x0B research_technology` / `0x0C cancel_technology`：`varint building_id`, `str8 technology_id`
- `0x0D place_wall`：`varint builder_id`, `str8 building_def_id`, `f32 sx, sy, ex, ey`（`flags` 编码 `include_gate`/`append_queue`）
- `0x0E set_gate_state`：`varint building_id`, `u8 gate_code(0=auto,1=open,2=locked)`
- `0x0F match_end`：`u8 winner(0|1)`（仅允许在 `SCHEDULE` 中由主机以 `seq=0` 发出）

实现入口：`multiplayer_service_python/wire.py`、`multiplayer_service_python/protocol.py`、`multiplayer_service_python/matchmaking.py`、`scripts/network/wire_codec.gd`、`scripts/network/fair_lockstep.gd`、`scripts/network/network_session.gd`。
