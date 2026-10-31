# 联机观战

在联机大厅选择「观看对战」，刷新正在进行的对局列表，点击某局进入。可切换队伍 1、队伍 2 视角或全图；全图关闭本地迷雾遮挡。镜头移动、缩放、单位信息和小地图定位可用，移动、攻击、采集、建造、训练、研究和 AI 托管均禁止。

## 协议 v3 加入流程

1. `list_matches` 或 `GET /api/matches` 返回已开局对局的双方名称、文明、时长和观众数量。
2. `watch_match {match_id}` 返回 `spectate_started`，包含显式 `role:"spectator"`、双方名册、随机 `host_team`、地图种子和模拟参数。观众没有玩家队伍。
3. 观众场景加载完成后发送 `watch_ready`，再发送 `request_keyframe`。服务生成请求 ID 并向主机发出 `keyframe_request`。
4. 主机在当前已完成帧的边界返回 `keyframe {request_id,tick,state,checksum}`。服务将它定向转给请求者；不会周期发送全量状态。
5. 观众恢复所有实体及隐藏模拟状态，验证摘要后，从关键帧的 tick 接着处理增量操作帧。关键帧之前收到的帧被忽略，之后不允许跳过任何帧。

关键帧包含尚未完成的移动、采集、攻击、训练、建造和研究等状态，所以观众中途加入后可以独立继续运算。缺帧或失步时重新请求当前关键帧；请求有间隔和超时限制，多个同时加入的观众可以共用一次主机响应。

观众不参与双方玩家的 `ack` 等待。退出观战只解除观众关系，不影响对局或排行榜；慢观众只会断开自己的连接。每局默认最多 16 名观众，可用 `AOE2_MP_MAX_SPECTATORS_PER_MATCH` 调整。视角选择始终不改变单位归属或网络权限。

当前回归使用 `tools/test_incremental_e2e.py`，覆盖真实玩家推进、晚加入、关键帧恢复后继续增量同步和最终状态一致。服务端 `tests/test_spectators.py`、`tests/test_incremental_sync.py` 覆盖越权、请求路由和观众连接清理；UI 回归为 `tests/run_spectator_ui.gd`。完整格式见 [联机协议](multiplayer.md)。
