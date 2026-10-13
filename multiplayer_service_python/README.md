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
docker run --rm -p 8001:8001 aoe2-multiplayer
```

公网部署可在反向代理后使用 `wss://域名/ws` 并转发 WebSocket Upgrade。HTTPS 网页客户端也应使用 `wss://`。房间和队列保存在单进程内存中，必须只启动 **一个 worker**；重启会结束现有对局。

## 支持范围

- FIFO 双人自动配对、文明选择、准备同步、取消匹配、心跳和超时清理。
- Python 校验消息结构、连接所属房间、主客身份、递增序号、大小和速率。
- team 0 客户端负责游戏模拟；team 1 发出命令并接收 10 Hz 世界快照。主机验证单位所有权、视野、地图边界、资源和文明限制。
- 同步移动、采集、建造、训练、攻击、生命、死亡、投射物、资源、人口及胜负；双方仅操作本方阵营，联机关闭迷雾调试切换。
- 对手退出/掉线判另一方获胜；服务中断或双方未准备超时会结束对局，不虚构胜者。

这是可信玩家之间的联机版本：服务不运行战斗模拟，主机能修改世界状态，完整快照也可被修改过的客户端读取。**不适用于要求反作弊的竞技排位**。当前只支持默认地图，不含账号、排行榜、断线重连、主机迁移或持久化战绩。

## 配置

环境变量均以 `AOE2_MP_` 开头；完整字段见 `settings.py`。常用默认值：

- `HOST=127.0.0.1`、`PORT=8001`。
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

端到端测试会临时启动本机服务和两个独立 Godot 进程，验证匹配、主客移动、客方建造/训练/采集/攻击、出生/死亡/移除、资源人口同步及城镇中心摧毁后的胜负。加速建造/训练仅在测试进程内生效；测试结束自动清理启动的进程，日志保存在 `.godot/multiplayer-e2e-*`。

Godot 专项脚本：`tests/run_online_lobby.gd`、`tests/run_network_runtime.gd`、`tests/run_network_recovery.gd`。使用 `Godot --headless --path . --script res://tests/文件名.gd`；受限 Windows 环境可用 `--log-file` 显式指定仓库 `.godot` 下的绝对日志路径。

协议与客户端实现见 [联机说明](../docs/multiplayer.md)。
