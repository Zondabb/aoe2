# 联机观战

在主菜单打开「联机对战」，填写与对战玩家相同的服务地址，点击「观看对战」。列表显示正在进行且已发布首个快照的对局、双方昵称、持续时间和观众人数，每 5 秒刷新，也可手动刷新。点击某行「观战」进入该对局；不需要加入匹配队列。

战场左上角的观战下拉框支持：

- 全图：解除战争迷雾，显示双方当前单位与建筑；资源栏默认显示队伍 1。
- 队伍 1 / 队伍 2：使用对应队伍的当前视野和探索记录，资源栏也切换到对应队伍，并把镜头定位到其基地。

观众可以移动和缩放镜头、通过小地图定位、选中可见对象查看信息。观众不能移动或攻击、采集、建造、生产、研究科技、改变城门状态或启用 AI 托管。视角切换只改变画面，观众没有任何可控制队伍。观众退出或断线不影响比赛、胜负和排行榜；双方比赛结束时，观众也会收到结果并可返回大厅。

## 部署与兼容

使用更新后的 `multiplayer_service_python` 与游戏客户端，共用原来的 WebSocket 端口和 `/ws` 路径。HTTP `GET /api/matches` 也可读取同样的列表。默认每局最多 16 位观众，列表最多 64 局；可配置 `AOE2_MP_MAX_SPECTATORS_PER_MATCH`、`AOE2_MP_MAX_LISTED_MATCHES`，Compose 已转发这些配置。

协议新增 `list_matches`、`watch_match` 和 `watch_ready`，响应为 `matches`、`spectate_started` 和已有的 `snapshot` / `match_ended`。服务只保留每局最新快照。观众握手先收到一份缓存快照，在场景与实体加载完成后发送 `watch_ready`，再接收最新快照和持续同步，避免加载期间积压大量帧。旧玩家匹配和命令协议保留兼容；旧服务不支持观战列表。

服务端维护独立观众身份，拒绝观众发送玩家命令、准备、快照、结算或直接加入匹配。客户端传输、对局运行时、输入和界面也分别限制操作。当前仍是可信主机模式，观战使用主机发布的全量世界快照；这是实时观战，不含延迟直播、录像回放或观战聊天。

双方探索掩码随快照同步，因此晚加入仍能查看已探索区域。静态物件的离开视野记忆从观众加入后逐渐形成，不提供完整的历史录像。

## 验证

```powershell
python -m pytest multiplayer_service_python/tests -q
Godot_console.exe --headless --path . --script res://tests/run_spectator_network.gd
Godot_console.exe --headless --path . --script res://tests/run_spectator_ui.gd
python tools/test_spectator_e2e.py --godot "<Godot console executable>"
```

端到端测试启动本机服务、两名真实 Godot 玩家和两次晚加入观众，验证视角切换、只读权限、离开不影响比赛、结束通知和排行榜隔离。测试使用临时数据库，不调用外部模型。
