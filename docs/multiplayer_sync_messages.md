# 联机同步消息详解（online_fair，协议 v9）

玩家通过 WebSocket 的 `/ws` 与 Python 中转服务交换 JSON 文本，每条消息是一个对象，由 `type` 区分。主机负责安排输入和发布执行结果，两台玩家电脑各自推进模拟。观众从关键帧开始，按已完成的操作帧回放。服务保存房间、角色和帧进度，按连接身份校验和转发消息。

以下示例每行是一条消息。同一段若列出多个方向，按正文顺序阅读。为方便辨认，`"H"` 代指该帧实际的 64 位小写十六进制 SHA-256，`"M"` 和 `"R"` 分别代指 32 位小写十六进制房间 ID 和关键帧请求 ID。时间戳是进程单调时钟的微秒数。队伍编号为 0 或 1，主机身份由 `host_team` 指定。

## 从一次右键移动看稳定期的五条消息

假设队伍 0 是主机，队伍 1 是客机。2 倍速下每秒运行 60 个逻辑 tick，每 3 tick 一个网络帧。客机在输入基准 tick 294 下令，让单位 10 前往地图坐标 [30,36]。以 100 ms 输入预算计算，目标边界是 300。假设消息及时抵达、单位可控：

1. **客机 → 服务 → 主机：提交意图。** `seq` 是本队本局递增的输入编号。服务转发时在外层增加 `"team":1`。主机玩家自己的输入直接进本地调度队列，省去这次上行。

~~~jsonl
{"type":"command","seq":42,"source_tick":294,"execute_tick":300,"command":{"op":"move","unit_id":10,"pos":[30,36]}}
~~~

2. **主机 → 服务 → 客机：发布执行计划。** `tick` 标识本网络帧结束的逻辑边界，`execute_at_usec` 是该帧开始执行的主机时刻。双方按相同顺序应用输入并推进三步。主机会提前准备连续的未来帧；迟到的有效输入可能排到更晚的未发布帧。

~~~jsonl
{"type":"input_step","tick":300,"execute_at_usec":5100000,"commands":[{"team":1,"seq":42,"command":{"op":"move","unit_id":10,"pos":[30,36]}}]}
~~~

3. **主机 → 服务：发布完成帧。** `commands` 记录供回放的已接受操作；`results` 用队伍和序号标记输入是否被接受；`checksum` 描述三步执行后的状态。`accepted:true` 表示移动指令生效，单位走到目的地可能还需要许多帧。

~~~jsonl
{"type":"frame","tick":300,"commands":[{"team":1,"command":{"op":"move","unit_id":10,"pos":[30,36]}}],"checksum":"H","results":[{"team":1,"seq":42,"accepted":true}]}
~~~

4. **服务 → 客机或观众：按角色分发。** 已就绪观众收到上面完整的 `frame`。客机已按计划执行移动，收到的是下面这条。服务只在客机的 `commands` 中保留 `match_speed`。公平调度的速度参数还通过调度消息传递。

~~~jsonl
{"type":"frame","tick":300,"commands":[],"checksum":"H","results":[{"team":1,"seq":42,"accepted":true}]}
~~~

5. **客机 → 服务 → 主机：确认完成。** 客机等本地执行和主机完成消息都到齐，比较摘要，并检查本地计算出的每条输入结果都出现在主机结果里。通过后用本地摘要发送 `ack`；服务转发时增加 `team`。主机按 tick 核对自己保存的摘要。比对失败走下文的关键帧恢复流程。

~~~jsonl
{"type":"ack","tick":300,"checksum":"H"}
~~~

**空帧与拒绝。** 无人下令时，双方仍在模拟行走、采集和战斗，因此仍有 `input_step`（空数组）、`frame`（通常两个空数组）和 `ack`。若输入 42 被玩法逻辑拒绝，完成帧可包含 `{"team":1,"seq":42,"accepted":false}`，而回放列表里没有该移动。调度阶段拒绝的输入也可以随完成帧返回。语法或身份校验失败则可能由服务直接返回 `error`。

## 托管玩家的输入

每位玩家在自己的游戏中选择 AI 地址。游戏把本队观察和文字意图通过 HTTP 发送给该地址，收到决策后在本机检查会话、有效期、重复命令和单位归属，再把实体 ID 转成对局 ID。例如 AI 返回带任务号的移动决策，进入联机协议的就是上例中的普通 `move`。开关、连接状态、URL、凭据、任务号和提示词留在各自的游戏与 AI 服务之间。取消托管停止新的提交，已经排入联机时间线的操作继续执行。

## 批量输入和调度边界

编队移动时，客机可把多个单位各自的目的地装入一条 `command_batch`。下面两项分别占序号 43、44，共用输入基准和期望执行 tick。服务给整个信封增加 `team` 后转发；主机逐项排队和判定，结果仍按各自序号返回。

~~~jsonl
{"type":"command_batch","seq":43,"source_tick":300,"execute_tick":306,"commands":[{"op":"move","unit_id":10,"pos":[31,36]},{"op":"move","unit_id":11,"pos":[33,36]}]}
~~~

| 字段或结构 | 约束与含义 |
|---|---|
| `source_tick`、`execute_tick` | 均为非负 3 的倍数；后者必须晚于前者，最多相差 180 tick。服务另检查相对于房间进度的上限。 |
| 单条 `command` | 对象必须有字符串 `op`；其余参数随玩法操作变化。禁止在玩法对象内自报队伍、玩家、房间或主机身份。 |
| 输入批次 | 1～64 条，序号连续。单个调度帧最多 62 条，所以一个批次可能跨多个执行帧。 |
| `input_step.commands[]` / `input_frame.commands[]` | 每项含 `team,seq,command`；正序号用于玩家输入。托管产生的操作也使用玩家普通正序号，内部终局操作使用 0。每项仅允许这三个字段。 |
| `frame.commands[]` / `frame.results[]` | 前者每项为 `team,command`，最多 64 项；后者每项为 `team,seq,accepted`，最多 256 项。数组必填，可为空。 |
| 大小 | 批量输入、调度输入帧和完成帧各有 256 KiB 上限。单个玩法指令另受服务配置限制。 |

## 匹配与开始

客户端发送 `join_queue`；服务先发 `queued`，配对后分别发 `match_found`。昵称去除首尾空格后为 1～24 字符；当前文明值为 `chinese` 或 `teutons`。下面示例是队伍 1 的视角。双方各发一次 `ready` 后，服务向双方发送 `start`。随机种子、逻辑频率、每帧步数和主机身份由服务在消息中指定。

~~~jsonl
{"type":"join_queue","protocol_version":9,"name":"小林","civ":"teutons"}
{"type":"queued"}
{"type":"match_found","match_id":"M","team":1,"players":[{"team":0,"name":"阿青","civ":"chinese"},{"team":1,"name":"小林","civ":"teutons"}],"protocol_version":9,"host_team":0,"seed":12345,"tick_rate":30,"frame_ticks":3}
{"type":"ready"}
{"type":"start","match_id":"M","protocol_version":9,"host_team":0,"seed":12345,"tick_rate":30,"frame_ticks":3}
~~~

排队时，客户端可发第一条取消；服务回复第二条。若由排队超时触发，服务改发第三条。

~~~jsonl
{"type":"cancel_queue"}
{"type":"queue_cancelled"}
{"type":"queue_cancelled","reason":"queue_timeout"}
~~~

## 对时、启动与调速

两个玩家都可以发 `clock_probe`；对端原样回送探针编号和发起时刻，并填写自己收到时的时间。中转转发两种消息时都增加发送方的 `team`。发起方用本地收回时间估算往返耗时；客机据此估算与主机的时钟偏差。开始采样时约每 200 ms 一次，取得三个样本后约每秒一次。

~~~jsonl
{"type":"clock_probe","nonce":7,"sent_usec":4000000}
{"type":"clock_reply","nonce":7,"sent_usec":4000000,"received_usec":2170000}
~~~

启动时，主机先发布计划 `input_frame`；客机有了计划并完成必要的对时后，用 `input_ack` 确认准备进度，服务向主机转发时补上 `team`。主机通过 `input_commit` 给已准备帧指定执行时刻。这个确认描述的是准备进度，执行后的确认才叫 `ack`。

~~~jsonl
{"type":"input_frame","tick":3,"commands":[]}
{"type":"input_ack","tick":3}
{"type":"input_commit","tick":3,"execute_at_usec":2000000,"speed":2.0,"input_delay_ticks":6,"delay_from_tick":0}
~~~

稳定期每帧只发一条合并的 `input_step` 来安排执行。调度参数变化时额外带 `timing`，例如切到 3 倍速；后续相同参数可省略。`speed` 范围为 0.25～4，`input_delay_ticks` 表示输入预算的逻辑步数，`delay_from_tick` 标记该规则从哪个输入基准 tick 生效。1、2、3 倍速的名义 100 ms 分别对应 3、6、9 tick。

~~~jsonl
{"type":"input_step","tick":306,"execute_at_usec":5200000,"commands":[],"timing":{"speed":3.0,"input_delay_ticks":9,"delay_from_tick":306}}
~~~

## 关键帧与失步恢复

客机初始同步、校验不一致或观众需要起始状态时，由需要状态的一端发 `request_keyframe`。服务分配请求 ID，用 `keyframe_request` 通知主机。主机在完成帧边界采集世界，返回当前 tick 和摘要；服务用请求 ID 定向分发给等待者。接收方恢复现场并校验，再继续推进。

~~~jsonl
{"type":"request_keyframe"}
{"type":"keyframe_request","request_id":"R"}
{"type":"keyframe","request_id":"R","tick":300,"checksum":"H","codec":"zlib","raw_size":546604,"data":"<完整压缩数据的 Base64>"}
~~~

`raw_size` 是压缩前 UTF-8 JSON 的字节数。`data` 是 zlib 压缩后再做 Base64 的字符串，示例省略实际内容。服务检查解压长度和 JSON 结构，转发压缩信封。协议也接受明文结构 `{"type":"keyframe","request_id":"R","tick":300,"checksum":"H","state":{…}}`。`state` 包含模拟器捕获的完整世界和 `fair`，后者包括 `input_delay_ticks,speed,delay_schedule`。关键帧后的计划可重发，接收方据此重新衔接未来帧。

## 观战、结束和连接管理

观众发送 `list_matches`，服务返回正在进行的房间，含阵容、已进行秒数和观众数。选房后发送 `watch_match`，服务回 `spectate_started`。场景加载后观众发 `watch_ready`，通过关键帧取得起点，再回放完整 `frame`。观众的进度不会阻塞玩家。

~~~jsonl
{"type":"list_matches"}
{"type":"matches","matches":[{"match_id":"M","players":[{"team":0,"name":"阿青","civ":"chinese"},{"team":1,"name":"小林","civ":"teutons"}],"elapsed_seconds":95,"spectator_count":0}]}
{"type":"watch_match","match_id":"M"}
{"type":"spectate_started","match_id":"M","role":"spectator","players":[{"team":0,"name":"阿青","civ":"chinese"},{"team":1,"name":"小林","civ":"teutons"}],"protocol_version":9,"host_team":0,"seed":12345,"tick_rate":30,"frame_ticks":3}
{"type":"watch_ready"}
~~~

对局正常结束时主机上报胜方队伍，服务发出终局消息。`reason` 说明结束原因。客户端也可用 `leave` 主动离开；观众离开只退出观战。

~~~jsonl
{"type":"finish_match","winner":1}
{"type":"match_ended","match_id":"M","winner":1,"reason":"completed"}
{"type":"leave"}
~~~

应用层心跳由客户端发 `ping`、服务回 `pong`。协议或房间状态异常时服务发 `error`，其中 `code` 是机器可读原因，`message` 是说明文字。例如非主机尝试宣布胜方会被拒绝。

~~~jsonl
{"type":"ping"}
{"type":"pong"}
{"type":"error","code":"forbidden","message":"Only the host may finish a match"}
~~~

## 实现入口

- [Python 协议字段与校验](../multiplayer_service_python/protocol.py)
- [中转路由、角色和房间生命周期](../multiplayer_service_python/matchmaking.py)
- [Godot 公平调度、执行与结果核对](../scripts/network/fair_lockstep.gd)
- [Godot 连接收发](../scripts/network/network_session.gd)与[关键帧编码](../scripts/network/snapshot_codec.gd)
- [流量测量方法与实测数据](multiplayer_performance.md)
