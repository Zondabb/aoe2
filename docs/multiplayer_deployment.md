# 联机服务 Docker Compose 部署

服务负责双人匹配、WebSocket 中继和 Web 排行榜，游戏连接 `/ws`，健康检查为 `/healthz`，排行榜为 `/` 或 `/leaderboard`。Compose 默认发布服务器 TCP 8001，配置自动重启、健康检查、日志轮转和战绩数据卷。房间和队列在单进程内存中，保持一个容器、一个 worker；重启或更新会结束正在进行的对局，已结算战绩保留在 SQLite 中。

## 1. 启动服务器

服务器需安装并启动 Docker Engine 与 Docker Compose v2，使用 Linux 容器。在仓库根目录执行：

```sh
cd multiplayer_service_python
cp .env.example .env
docker compose config --quiet
docker compose up -d --build
docker compose ps
```

Windows PowerShell 使用 `Copy-Item .env.example .env` 替代 `cp`。其余 `docker compose` 命令相同。首次构建需要联网下载 Python 基础镜像和依赖。

默认监听 `0.0.0.0:8001`，局域网或云服务器的防火墙/安全组需放行 TCP 8001。两个客户端使用服务器的局域网 IP 或公网 IP，不能填写容器内部 IP；远程玩家填写 `127.0.0.1` 会连接玩家自己的电脑。

检查服务：

```sh
curl http://127.0.0.1:8001/healthz
docker compose logs --tail=100 -f multiplayer
```

PowerShell 可使用 `Invoke-RestMethod http://127.0.0.1:8001/healthz`。健康接口应返回 `status: ok` 及当前连接、队列和房间数量；`docker compose ps` 的健康状态需要等待首次检查。

浏览器打开 `http://服务器IP:8001/` 查看排行榜；修改映射端口后使用对应端口，例如 `http://服务器IP:18001/`。无须额外部署 Web 服务。榜单按昵称累计胜率、胜场、总场次，具体计分规则见 [服务 README](../multiplayer_service_python/README.md#web-排行榜)。

## 2. 修改监听地址与端口

编辑服务目录的 `.env`：

```dotenv
AOE2_MP_BIND_IP=0.0.0.0
AOE2_MP_PUBLIC_PORT=18001
AOE2_MP_MAX_CONNECTIONS=128
AOE2_MP_MAX_QUEUE=128
AOE2_MP_IDLE_TIMEOUT=30
AOE2_MP_QUEUE_TIMEOUT=120
AOE2_MP_READY_TIMEOUT=30
AOE2_MP_MATCH_TIMEOUT=10800
```

`AOE2_MP_PUBLIC_PORT` 是玩家连接的宿主机端口；容器内部始终使用 8001，因此无需修改健康检查。`AOE2_MP_BIND_IP` 是服务器本机的绑定地址，不是客户端或另一台服务器的 IP。仅供同机反向代理使用时可设置为 `127.0.0.1`。

修改后执行 `docker compose up -d` 重建容器，放行对应 TCP 端口。改为 18001 后健康地址为 `http://服务器IP:18001/healthz`。

## 3. 配置游戏的服务器 IP 与端口

你从 Godot 编辑器运行时，修改项目的 `data/game_settings.cfg`：

```ini
[multiplayer]
host="192.168.1.10"
port=18001
use_tls=false
```

将 `host` 替换为服务器 IP，`port` 与 Compose 的 `AOE2_MP_PUBLIC_PORT` 保持一致。字符串必须加引号，`host` 只填写 IP 或域名，不填 `ws://`、端口或 `/ws`。示例会自动生成 `ws://192.168.1.10:18001/ws`，游戏启动时载入，大厅自动填写该地址。停止并重新运行游戏后生效。

导出的桌面游戏可在 `aoe2.exe` 同目录创建 `game_settings.cfg`，只包含上述 `[multiplayer]` 即可，无需重新打包。加载优先级从低到高：

1. 打包默认 `res://data/game_settings.cfg`。
2. 桌面可执行文件同目录的 `game_settings.cfg`（编辑器和 Web 版本不读取此项）。
3. `user://game_settings.cfg` 中的 `[multiplayer]`。

联机字段逐项覆盖；已有仅包含 `[ai]` 的用户配置不会丢失默认联机地址。Windows 用户配置通常位于 `%APPDATA%\Godot\app_userdata\AoE2 RTS\game_settings.cfg`。大厅仍可临时修改完整服务地址，退出游戏后按配置文件重新载入。IP 支持 IPv4、IPv6，域名也可使用；端口范围 1～65535。

两台电脑使用相同的服务配置，打开「联机对战」，填写昵称、选择文明并点击「开始匹配」。应先显示等待，双方加入后自动进入同一对局。

开发环境还可运行实际双客户端回归，连接已部署的服务（测试会创建并结束一场对局）：

```sh
python tools/test_multiplayer_e2e.py --godot /path/to/Godot --server-url ws://127.0.0.1:18001/ws
```

此命令在仓库根目录执行，连接已部署服务时仅需 Python 标准库。替换 Godot 路径及服务端口，结果应显示 `MULTIPLAYER E2E PASSED`。不传 `--server-url` 时会启动本机临时 Python 服务，此时需先安装 `multiplayer_service_python/requirements.txt`。

## 4. HTTPS / WSS 部署

公网使用 TLS 时，由现有 Nginx、Caddy 或云网关代理到本服务。代理必须支持 WebSocket Upgrade，转发 `/ws`，并允许长连接。排行榜还需转发普通 HTTP 路径 `/`、`/leaderboard`、`/static/` 和 `/api/leaderboard`，推荐将该域名整体代理到服务。HTTPS 网页游戏应连接 `wss://` 地址。游戏配置示例：

```ini
[multiplayer]
host="games.example.com"
port=443
use_tls=true
```

Compose 服务自身提供普通 HTTP/WebSocket；`use_tls=true` 不会给 Python 容器自动启用证书。请先配置有效 TLS 代理，再设置客户端 TLS。

## 5. 更新、停止和排错

```sh
# 更新服务器代码后重新构建并启动
docker compose up -d --build
# 查看日志与服务状态
docker compose logs --tail=100 multiplayer
docker compose ps
# 停止并移除本组容器
docker compose down
```

健康检查失败时，先查看日志确认端口、依赖和环境变量格式。健康状态标记为 unhealthy 不会单独触发自动重启；进程退出由 `restart: unless-stopped` 处理。若端口被占用，修改 `.env` 和客户端端口。健康接口可访问但无法匹配时，检查 WebSocket `/ws` 的代理转发、客户端地址及双方是否连接同一个服务。地址配置未生效时，检查高优先级的用户配置，再重新启动游戏。

此服务按可信玩家的双人对战设计，没有账号或断线重连；排行榜按昵称持久化累计，对战主机由服务随机分配，双方按协议 v4 的固定步长和增量操作同步运算。不要通过增加 worker 或容器副本扩容，独立进程间不会共享房间。

## 战绩保存和备份

Compose 将 `leaderboard_data` 命名卷挂载到 `/data`。SQLite 文件为 `/data/leaderboard.sqlite3`，容器内以非 root 用户写入。更新镜像、重建容器、普通 `docker compose down` 都保留卷；不要在需要保留战绩时执行 `docker compose down -v`。若自行改用宿主机目录绑定，需确保 UID/GID `65532:65532` 对目录有写权限。

运行中备份使用 SQLite 自带备份接口，避免只复制数据库文件却遗漏 WAL 中的新战绩：

```sh
docker compose exec multiplayer python -c "import sqlite3; sqlite3.connect('/data/leaderboard.sqlite3').backup(sqlite3.connect('/data/leaderboard-backup.sqlite3'))"
docker compose cp multiplayer:/data/leaderboard-backup.sqlite3 ./leaderboard-backup.sqlite3
```

原版本只把对局保存在内存里，升级后的统计从新完成的对局开始累计。

Compose 字段说明见 [Docker Compose 服务配置文档](https://docs.docker.com/reference/compose-file/services/)。游戏协议及同步方式见 [联机说明](multiplayer.md)。

## 部署验证记录

2026-10-12：Compose 配置校验、镜像构建、`/healthz` 和容器健康检查通过；使用 `127.0.0.1:18001` 临时映射测试后已清理容器。两个真实 Godot 客户端完成 32 项端到端检查，覆盖匹配、移动、建造、训练、采集、攻击、复制实体移除和胜负同步。游戏配置 29 项、大厅流程 45 项检查通过。

联机服务主体本次未改动。容器中的现有 Python 单元测试为 16 项通过、2 项失败，失败发生在 Starlette TestClient 退出 WebSocket 上下文时的 `concurrent.futures.CancelledError`；实际容器 WebSocket 对战验证通过。该单测收尾问题仍需单独处理，不应将其结果表述为全量测试通过。

2026-10-21：新增 Web 排行榜与 SQLite 持久战绩。修复 WebSocket 取消可能中断断线结算及清理的问题，上述旧收尾失败已在当前测试环境解决。联机服务回归 **41 项通过**；桌面/手机网页的排序、搜索、分页、文本转义和网络错误恢复通过浏览器验证。

原生 Python 服务与最终 Docker 镜像分别通过两个真实 Godot 客户端的 **32 项对战检查**；每局结束后，网页接口准确反映两位玩家各一场、仅胜者一胜。容器以 UID 65532 运行，删除并重建测试容器后，专用数据卷内原有战绩完整保留，新对局可继续累计。测试使用独立数据库，测试容器及专用数据卷已清理。
