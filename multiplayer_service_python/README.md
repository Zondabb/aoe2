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

## 实时观战

联机大厅可查看正在对战的局并点击观战。只有双方已开局且主机已提交首份状态快照的对局出现在列表中。观众加入后立即收到最新完整快照，随后与客端一起接收主机的实时快照；不需要等待本局重新开场。

观众使用独立的服务端身份，没有队伍控制权。观众发送玩家指令、AI 托管开关、准备、快照、胜负结算或排队请求都会被服务拒绝。观众离开、掉线、空闲超时或接收过慢只会清理该观众，不会结束双方对局或产生排行榜战绩；双方结束对局时所有观众一起收到结束通知。

观战局是公开的完整状态流。游戏可以切换双方视角或解除迷雾；视角切换仅改变本机显示。游戏主机仍然负责模拟，本服务不运行战斗或额外维护一套观众模拟。

WebSocket 扩展（沿用 `/ws`，兼容现有玩家消息）：

- `{"type":"list_matches"}` → `{"type":"matches","matches":[...]}`，每项包含 `match_id`、`players`（队伍/昵称/文明）、`elapsed_seconds`、`spectator_count`。
- `{"type":"watch_match","match_id":"32位对局ID"}` → `spectate_started`（`role="spectator"`、`host_team=0`、对局 ID 和双方名单），随后立即发送最近一份 `snapshot`。
- 场景加载完成后发送 `{"type":"watch_ready"}`，服务立即重放最新快照并开始持续转发。加载期间仅保留房间的最新快照，不向该观众堆积后续帧，避免晚加入时堵塞连接；重复发送会重放最新快照，不改变身份或对局。
- 后续仅接收 `snapshot` 与 `match_ended`；观众可以发送 `ping`、`list_matches`、`watch_ready` 或 `leave`。离开观战后可以重新排队，普通玩家不能发送 `watch_ready`。
- 对局已结束/尚不可用返回 `match_unavailable`，观众满员返回 `spectators_full`，均可恢复并刷新列表重试。

另有只读 HTTP 列表 `GET /api/matches`，返回 `{"matches":[...]}`，设置 `Cache-Control: no-store`。不包含队伍指令、地图内容或状态快照。

默认每局最多 16 位观众、列表最多返回 64 局，分别可通过 `AOE2_MP_MAX_SPECTATORS_PER_MATCH`、`AOE2_MP_MAX_LISTED_MATCHES` 配置。所有连接仍共享连接总数和收发速率限制；每局只缓存最新快照，慢观众不会拖住主机。

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
- team 0 客户端负责游戏模拟；team 1 发出命令并接收 10 Hz 世界快照。主机验证单位所有权、视野、地图边界、资源和文明限制。
- 同步移动、采集、建造、训练、攻击、生命、死亡、投射物、资源、人口及胜负；双方仅操作本方阵营，联机关闭迷雾调试切换。
- 对手退出/掉线判另一方获胜；服务中断或双方未准备超时会结束对局，不虚构胜者。

这是可信玩家之间的联机版本：服务不运行战斗模拟，主机能修改世界状态，完整快照也可被修改过的客户端读取。**不适用于要求反作弊的竞技排位**。当前支持默认地图和持久化战绩排行榜，不含账号、断线重连或主机迁移。

## 配置

环境变量均以 `AOE2_MP_` 开头；完整字段见 `settings.py`。常用默认值：

- `HOST=127.0.0.1`、`PORT=8001`。
- `LEADERBOARD_DB`：SQLite 文件路径，默认服务目录的 `data/leaderboard.sqlite3`；Docker 默认 `/data/leaderboard.sqlite3`。
- `MAX_CONNECTIONS=128`、`MAX_QUEUE=128`。
- `MAX_MESSAGE_BYTES=524288`、`MAX_COMMAND_BYTES=16384`。
- `MESSAGES_PER_SECOND=90`、`MESSAGE_BURST=180`。
- `IDLE_TIMEOUT=30`、`QUEUE_TIMEOUT=120`、`READY_TIMEOUT=30`、`MATCH_TIMEOUT=10800`（秒）。

客户端每 8 秒发送应用层 `ping`。输出队列或带宽超限的连接会关闭，相关房间会清理。

## 验证

```powershell
./multiplayer_service_python/.venv/Scripts/python.exe -m pip install -r multiplayer_service_python/requirements-dev.txt
./multiplayer_service_python/.venv/Scripts/python.exe -m pytest multiplayer_service_python/tests -q
./multiplayer_service_python/.venv/Scripts/python.exe tools/test_multiplayer_e2e.py --godot "C:/path/to/Godot_console.exe"
```

端到端测试会临时启动本机服务和两个独立 Godot 进程，验证匹配、主客移动、客方建造/训练/采集/攻击、出生/死亡/移除、资源人口同步及城镇中心摧毁后的胜负，并检查两位玩家各计一场、胜者计一胜。使用临时独立数据库；加速建造/训练仅在测试进程内生效；测试结束自动清理启动的进程，日志保存在 `.godot/multiplayer-e2e-*`。

Godot 专项脚本：`tests/run_online_lobby.gd`、`tests/run_network_runtime.gd`、`tests/run_network_recovery.gd`。使用 `Godot --headless --path . --script res://tests/文件名.gd`；受限 Windows 环境可用 `--log-file` 显式指定仓库 `.godot` 下的绝对日志路径。

协议与客户端实现见 [联机说明](../docs/multiplayer.md)。
