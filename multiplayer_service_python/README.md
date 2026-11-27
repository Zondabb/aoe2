# Python 联机匹配服务

为 Godot 游戏提供 1 对 1 匹配队列和 WebSocket 中继，默认端口 `8001`，与现有 AI 服务独立。主菜单选择「联机对战」即可使用。

## 本机启动

需要 Python 3.10+。在仓库根目录运行：

```powershell
python -m venv multiplayer_service_python/.venv
./multiplayer_service_python/.venv/Scripts/python.exe -m pip install -r multiplayer_service_python/requirements.txt
./multiplayer_service_python/.venv/Scripts/python.exe -m multiplayer_service_python.main
```

Linux/macOS 将解释器路径换成 `multiplayer_service_python/.venv/bin/python`。

打开两个游戏实例，在各自「联机对战」中填写 `ws://127.0.0.1:8001/ws`、昵称和文明，再点击「开始匹配」。双方加载默认双营地地图后开始，可取消等待、主动离开和结束后重新匹配。

健康检查：`GET http://127.0.0.1:8001/healthz`。

## 事件驱动二进制同步（协议 v10）

服务使用 **协议 v10**（已移除在线观战）。匹配时随机选择 `host_team=0` 或 `1`，并下发相同的地图 `seed`、`tick_rate=30`、`frame_ticks=3`。队伍编号决定单位归属，和主机身份独立。旧版 v1–v9 客户端收到 `protocol_mismatch`，客户端和服务需一起更新。

- **JSON 文本帧**：仅用于匹配队列（`join_queue`/`cancel_queue`）、准备（`ready`）、失步关键帧恢复（`request_keyframe`/`keyframe`）、终局（`finish_match`/`match_ended`）与低频保活（`ping`/`pong`）。
- **二进制帧**：局内时钟校准（`0x01`/`0x02`）、开局同种子时间线同步（`0x03 SYNC_INIT`）、玩家指令批量提交（`0x04 CMD_SUBMIT`）、两阶段日程确认（`0x05 SCHEDULE` / `0x06 SCHEDULE_ACK`）及 1 Hz 32-bit 摘要心跳（`0x07 HEARTBEAT` / `0x08 HEARTBEAT_ACK`）。无操作时不发送空帧；若 `SCHEDULE` 迟到，客机以 `accepted=0` 通知主机无损顺延，不触发关键帧重传。

健康检查：`GET http://127.0.0.1:8001/healthz`。服务不缓存全量世界状态，仅在异常失步时向请求者转发压缩关键帧。

## Web 排行榜

打开 `http://127.0.0.1:8001/` 或 `/leaderboard`，即可查看每位玩家的胜率、胜场和总场次。网页与游戏联机服务共用端口，支持昵称搜索、分页，以及按胜率、胜场、场次排序，每 20 秒自动更新。

战绩按大厅昵称累计（去首尾空白、Unicode NFC 归一化，区分字母大小写），同名视为同一玩家；改昵称会产生新记录。加入匹配时进入榜单，尚未完成计分对局的玩家显示 0 场、胜率「—」。当前没有账号验证，因此这是对战统计榜，不是防作弊竞技积分系统。

- 双方准备完成并开局后，主机正常结算的胜负计入统计。
- 开局后退出、掉线或连接超时，按服务判定为退出方负、对手胜。
- 匹配取消、准备阶段退出/超时、对局超时和服务关闭等无明确胜负情况不计入。
- 同昵称的双方仍可对战，但不计战绩，避免同一身份自战。
- 胜率 = 胜场 / 已结算总场次 × 100%。同一对局 ID 只统计一次，双方计数在同一数据库事务中更新。

战绩保存于 SQLite，默认 `multiplayer_service_python/data/leaderboard.sqlite3`，可通过 `AOE2_MP_LEADERBOARD_DB` 指定本机路径。重启后保留；旧版本未保存的历史对局无法追溯。Compose 自动使用 `/data/leaderboard.sqlite3` 与 `leaderboard_data` 命名卷，更新镜像和普通 `docker compose down` 不删除战绩。`docker compose down -v` 会删除该卷。

公开只读接口：`GET /api/leaderboard?sort=win_rate&q=昵称&limit=20&offset=0`。`sort` 支持 `win_rate/wins/games`，每页最多 100 人；返回 `players`（排名、昵称、胜场、总场次、百分制胜率）、总人数、已结算对局数与最近结算时间。搜索时保留所选排序中的全榜名次。数据库和写入接口不向网页公开。

## 局域网与部署

推荐使用 [Docker Compose 部署文档](../docs/multiplayer_deployment.md)，包含启动、端口、客户端 IP 配置、WSS 代理和更新步骤。

```sh
cd multiplayer_service_python
cp .env.example .env
docker compose up -d --build
```

Godot 游戏读取 `data/game_settings.cfg` 的 `[multiplayer] host/port/use_tls`，并自动填写大厅服务器地址。桌面发行版也可通过可执行程序同目录的 `game_settings.cfg` 配置服务地址。

```powershell
$env:AOE2_MP_HOST = "0.0.0.0"
./multiplayer_service_python/.venv/Scripts/python.exe -m multiplayer_service_python.main
```

两台电脑填写同一个地址，例如 `ws://192.168.1.10:8001/ws`，其中 IP 是服务所在电脑的局域网 IP。防火墙需允许 TCP 8001。

Docker 在仓库根目录运行：

```sh
docker build -t aoe2-multiplayer multiplayer_service_python
docker run --rm -p 8001:8001 -v aoe2-multiplayer-data:/data aoe2-multiplayer
```

公网部署可在反向代理后使用 `wss://域名/ws` 并转发 WebSocket Upgrade。HTTPS 网页客户端也应使用 `wss://`。房间和队列保存在单进程内存中，必须只启动 **一个 worker**；重启会结束现有对局。

## 支持范围

- FIFO 双人自动配对、文明选择、准备同步、取消匹配、心跳和超时清理。
- Python 校验消息结构、连接所属房间、主客身份、递增序号、大小和速率。
- 随机一方作为校验主机，双方同步运算，每秒最多 10 批增量操作。主机验证单位所有权、视野、地图边界、资源和文明限制；关键帧仅按请求发送。
- 同步移动、采集、建造、训练、攻击、生命、死亡、投射物、资源、人口及胜负；双方仅操作本方阵营，联机关闭迷雾调试切换。
- 对手退出/掉线判另一方获胜；服务中断或双方未准备超时会结束对局，不虚构胜者。

这是可信玩家之间的联机版本：服务不运行战斗模拟，主机能修改世界状态，完整状态也可被修改过的客户端读取。**不适用于要求反作弊的竞技排位**。当前支持默认地图和持久化战绩排行榜，不含账号、断线重连或主机迁移。

## 配置

环境变量均以 `AOE2_MP_` 开头；完整字段见 `settings.py`。常用默认值：

- `HOST=127.0.0.1`、`PORT=8001`。
- `LEADERBOARD_DB`：SQLite 文件路径，默认服务目录的 `data/leaderboard.sqlite3`；Docker 默认 `/data/leaderboard.sqlite3`。
- `MAX_CONNECTIONS=128`、`MAX_QUEUE=128`。
- `MAX_MESSAGE_BYTES=4194304`、`MAX_COMMAND_BYTES=16384`。
- `MESSAGES_PER_SECOND=300`、`MESSAGE_BURST=600`、`OUTGOING_QUEUE_SIZE=64`（每个连接待发送的消息数）。
- `BYTES_PER_SECOND=4194304`、`BYTE_BURST=8388608`。
- `KEYFRAME_REQUEST_INTERVAL=1`、`KEYFRAME_TIMEOUT=10`（秒）；房间请求间隔还会预留至少 25% 带宽供普通指令使用。
- `IDLE_TIMEOUT=30`、`QUEUE_TIMEOUT=120`、`READY_TIMEOUT=30`、`MATCH_TIMEOUT=10800`（秒）。

客户端每 8 秒发送应用层 `ping`。输出队列或带宽超限的连接会关闭，相关房间会清理。

## 验证

```powershell
./multiplayer_service_python/.venv/Scripts/python.exe -m pip install -r multiplayer_service_python/requirements-dev.txt
./multiplayer_service_python/.venv/Scripts/python.exe -m pytest multiplayer_service_python/tests -q
```

服务测试覆盖随机主机的两个分配结果、操作身份、连续帧序号、关键帧请求与响应路由、超时/退出清理、16 人并发观战请求合并以及排行榜隔离。旧版快照协议测试已迁移到 v9；游戏模拟和关键帧恢复的验证入口见下方联机说明。

协议与客户端实现见 [联机说明](../docs/multiplayer.md)。
