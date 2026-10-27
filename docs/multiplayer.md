# 联机匹配与对战

主菜单「联机对战」进入大厅，选择中国或条顿，输入昵称后开始匹配。服务地址自动读取 `game_settings.cfg` 的 `[multiplayer] host/port/use_tls`，默认 `ws://127.0.0.1:8001/ws`，也可在大厅临时修改。局域网使用服务所在电脑的 IP；启动、Docker Compose 部署和客户端配置见 [部署文档](multiplayer_deployment.md)及 [Python 服务 README](../multiplayer_service_python/README.md)。

匹配成功后自动加载默认 120 × 120 双营地地图。服务分配固定阵营 `0` 和 `1`，各自的相机、选择、指令、资源、迷雾、小地图和胜负展示使用本地阵营。对局不启动 AI 控制器或 AI 网关。右上角可「离开对局」，结束后可返回联机大厅再次匹配。

## 同步方式

Python 使用 FastAPI/asyncio 提供 FIFO 队列、房间生命周期和消息中继。team 0 是模拟主机，执行双方命令并每 0.1 秒生成一次完整快照；team 1 停止实体物理模拟，只更新快照中的位置、动画、生命、生产和经济状态。网络实体 ID 独立于进程内 `EntityRegistry` ID，主机执行时显式转换，避免不同客户端的创建顺序影响指令。

`scripts/input/player_commands.gd` 根据当前场景的联机标记路由指令，离线游戏沿用本地调用。`scripts/network/network_session.gd` 作为 Autoload 跨大厅与战场维持 WebSocket；`network_match.gd` 负责同步和命令权限验证。准备完成前暂停模拟，收到服务的 `start` 后开始。

当前模式信任模拟主机，不具备服务端反作弊。快照包含全场实体，普通客户端通过迷雾隐藏敌方，但修改客户端可读取数据。适用于熟人/局域网对战；竞技排位需要独立权威模拟服务及按玩家视野过滤状态。没有账号系统、竞技积分、重连、主机迁移、自定义地图同步。

## 战绩排行榜

在浏览器打开 `http://联机服务器IP:端口/` 或 `/leaderboard`，即可查看按昵称累计的胜率、胜场和总场次，支持搜索、分页和排序。网页与联机服务共用端口，无须更新游戏客户端协议。双方已开局且有明确胜者才计入；开局后退出/掉线计负，准备阶段中止及无胜负结束不计入。同名视为同一玩家，同昵称对局不计战绩。SQLite 保存战绩，Docker 使用持久数据卷。详见 [服务说明](../multiplayer_service_python/README.md#web-排行榜)。

## WebSocket 协议 v1

端点 `/ws`，UTF-8 JSON 文本帧。以下为客户端发往服务的消息，字段严格校验：

```json
{"type":"join_queue","protocol_version":1,"name":"玩家","civ":"chinese"}
{"type":"cancel_queue"}
{"type":"ready"}
{"type":"command","seq":1,"command":{"op":"move","unit_id":10,"pos":[30,36]}}
{"type":"snapshot","seq":1,"state":{"entities":[],"economies":[],"winner":-1}}
{"type":"finish_match","winner":0}
{"type":"leave"}
{"type":"ping"}
```

快照片段仅示意封装格式；实际 `economies` 必须含两方资源、人口、上限和预留人口，实体包含种类、定义、位置与完整表现状态。基础命令为 `move/stop/gather/build/attack/train/cancel_train/place_building`，实体 ID 使用网络 ID。

单位生产支持最多 15 项队列。建筑快照增加 `train_queue_ids`，与 `train_queue` 一一对应；`cancel_train` 携带 `building_id` 和稳定的 `queue_id`，由主机验证所属阵营并退款。详见 [单位生产队列](production_queue.md)，双方客户端应使用相同版本。

服务响应依次为 `queued`、`match_found`、`start`：

```json
{"type":"match_found","match_id":"随机房间ID","team":1,"host_team":0,"players":[{"team":0,"name":"甲","civ":"chinese"},{"team":1,"name":"乙","civ":"teutons"}]}
```

双方均 `ready` 后才允许转发。客方 `command` 转发给主机时由服务添加 `team:1`；客户端不能自行声明阵营。只有主机可以发送 `snapshot` 或 `finish_match`。`seq` 是每局独立递增正整数，重复或倒序拒绝。

终止响应 `match_ended` 包含 `match_id/winner/reason`。正常胜负为 `completed`，对手离开为 `opponent_left`；就绪超时 `ready_timeout`、对局期限 `match_timeout` 的 `winner` 为 `null`。`cancel_queue` 与配对发生竞态时会退出已创建的房间，之后返回 `queue_cancelled`。其他响应为 `pong`、`queue_cancelled` 和 `error`（`code/message`）。

服务维护有界输出队列，网络发送不持有匹配锁；慢连接、无心跳、超限消息会清理，防止阻塞其他房间。所有房间均为内存状态，部署限制为单 worker。

## 回归入口

联机大厅还提供「观看对战」，支持双方视角、全图与只读观战；使用方法与观众协议见 [联机观战](spectator.md)。

卡顿、倍速与连接断开原因及持续对局测试见 [联机同步性能排查](multiplayer_performance.md)。

- Python：`python -m pytest multiplayer_service_python/tests -q`。
- 实际双进程：`python tools/test_multiplayer_e2e.py --godot <Godot可执行文件>`。
- Godot：`run_online_lobby.gd` 检查大厅、文明与队列交互；`run_network_runtime.gd` 检查 JSON 快照、实体 ID、权限、旧帧和复制实体隔离；`run_network_recovery.gd` 检查场景切换间断线、结束界面及重新匹配入口。
- 既有菜单流程：`run_menu_flow.gd`。`docs/main_menu.md` 记录了全量旧测试原有的四项弓箭手/箭矢配置失败及观察视野测试生命周期错误。
