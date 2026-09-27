# Web 压缩包部署

发布目录为 `dist/web/`：保留 Godot 导出的 HTML、JS、WASM、PCK 和其他运行资源，以及同名 `.gz` / `.br` 压缩副本。`index.html` 与导出入口 HTML 内容相同，仍引用原导出文件名。压缩统计保存在目录外的 `dist/web-compression-report.json`，无需公开。

gzip 和 Brotli 均为无损传输压缩，不更改游戏代码、图片或字体。服务器根据浏览器的 `Accept-Encoding` 为同一个资源 URL 选择表示形式；浏览器解压后再交给 Godot。磁盘上同时保留原件和压缩件会增加部署目录体积，实际网络流量取决于协商结果。

## 生成与本地预览

需要 Node.js 18 或更新版本，无需安装 npm 依赖。从仓库根目录执行：

```sh
node tools/package_web.mjs --godot "你的 Godot 可执行文件绝对路径"
```

此命令使用 `Web` 预设重新导出当前项目到 `.godot/web-export/`，再生成 `dist/web/`；入口为 `index.html`。Godot 需已安装与编辑器版本匹配的 Web 导出模板。导出预设已排除测试、开发工具和未使用的预览素材，保留游戏配置、动态加载的精灵 JSON、地图数据、图片与完整中文字库。生成目录内的 `.gdignore` 防止 Godot 再次导入这些产物，请保留。

如果已通过 Godot 编辑器导出到 `web/`，也可以只压缩该目录：

```sh
node tools/package_web.mjs --input web --output dist/web-existing --entry "AoE2 RTS.html"
```

此时部署目录为 `dist/web-existing/`，原有 `AoE2 RTS.*` 名称保留，并添加 `index.html` 入口；使用 Docker 时需相应调整 `COPY` 路径。工具会检查 HTML 声明的 WASM / PCK 尺寸及每个压缩副本解压后的内容，发现不完整导出时停止。输出目录中若有其他构建的文件，也会停止；可改用新的 `--output` 目录。

预览新导出的压缩包并运行工具测试：

```sh
node tools/serve_web.mjs dist/web 8080
# 在另一个终端运行：
node --test tools/tests/test_web_package.mjs
```

打开 [本地预览](http://127.0.0.1:8080/)。预览服务支持 Brotli / gzip 协商、原文件回退、正确的 MIME 和 ETag；仅监听本机。当前云服务器没有安装 Nginx / Docker，线上使用下一节的 Python HTTPS 服务。

本次当前版本构建的全部运行文件合计为 **52.34 MB**，gzip 为 **22.52 MB**（减少约 57%），Brotli 为 **20.32 MB**（减少约 61%），以十进制 MB 计。最大文件 WASM 从 39.51 MB 降为 gzip 10.15 MB / Brotli 8.00 MB。这些是文件字节统计，不代表云端实测加载时长；每次构建的准确结果见压缩报告。PCK 中大部分图片和字体已由 Godot 压缩，额外收益较小。

## 发布到云服务器

线上机器：`106.12.81.171`，SSH 用户 `root`。Godot Web 导出只在安全上下文中启动，所以这台机器用 systemd 服务 `aoe2-web.service` 提供 HTTPS，而不是 Nginx 容器。证书在 `/etc/letsencrypt/live/106.12.81.171/`。部分网络会拦截 443，服务因此同时在 **80 端口接受 TLS**；普通 HTTP 会 301 到 `https://106.12.81.171:80/`。

| 项目 | 值 |
|---|---|
| 公开目录 | `/root/workspace/aoe2_web/public/` |
| 服务脚本 | `/root/workspace/aoe2_web/serve_https.py`（仓库副本：`deploy/web/serve_https.py`） |
| systemd | `aoe2-web.service` |
| 访问地址 | [https://106.12.81.171:80/](https://106.12.81.171:80/) ，若 443 通畅也可用 [https://106.12.81.171/](https://106.12.81.171/) |

不要把 SSH 密码写进仓库、脚本或本文件。优先用密钥登录：

```sh
ssh-copy-id root@106.12.81.171
```

### 1. 生成本地发布目录

本机已安装 Godot 4.7.1 与 Node.js 18+ 时，从仓库根目录重新导出并打包：

```sh
node tools/package_web.mjs --godot "D:\Program Files\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
```

若 `dist/web/index.html`、`index.js`、`index.wasm`、`index.pck` 及对应 `.gz` 已经是当前版本，可跳过这一步。

### 2. 上传静态文件

把整份 `dist/web/` 覆盖到服务器公开目录，不要只传 HTML。Windows 可用 OpenSSH 的 `scp`：

```sh
ssh root@106.12.81.171 "mkdir -p /root/workspace/aoe2_web/public"
scp -r dist/web/* root@106.12.81.171:/root/workspace/aoe2_web/public/
scp deploy/web/serve_https.py root@106.12.81.171:/root/workspace/aoe2_web/serve_https.py
```

Linux / macOS 可用 `rsync -av --delete dist/web/ root@106.12.81.171:/root/workspace/aoe2_web/public/`，同步后公开目录应只包含这一批构建产物。服务脚本不放在 `public/` 里，避免把 Python 源码当静态文件发出。

### 3. 重启服务

```sh
ssh root@106.12.81.171 "systemctl restart aoe2-web.service && systemctl is-active aoe2-web.service"
```

`serve_https.py` 会为 `Accept-Encoding: gzip` 选择同名 `.gz`，并设置 `Content-Encoding`、原文件 MIME、`Vary: Accept-Encoding`、`ETag` 和 `Cache-Control: public, max-age=0, must-revalidate`。不支持 gzip 的客户端仍拿到原文件。当前脚本未启用 Brotli 协商，`.br` 副本会随目录上传但不直接提供。

### 4. 线上检查

```sh
curl.exe -kI "https://106.12.81.171:80/"
curl.exe -kI -H "Accept-Encoding: gzip" "https://106.12.81.171:80/index.wasm"
curl.exe -kI -H "Accept-Encoding: identity" "https://106.12.81.171:80/index.wasm"
```

首页应为 `200` 且 `Content-Type: text/html`。WASM 在 gzip 请求下应为 `Content-Encoding: gzip`、`Content-Type: application/wasm`，体积约 10 MB；`identity` 请求无 `Content-Encoding`，体积约 39 MB。浏览器打开上述地址后应出现主菜单。证书若未匹配浏览器信任链，本机检查可加 `-k`，正式域名接入后再去掉。

## 使用 Docker / Nginx

先生成 `dist/web/`，再从仓库根目录执行：

```sh
docker build -f deploy/web/Dockerfile -t aoe2-web .
docker run --rm -p 8080:80 aoe2-web
```

打开 [本地页面](http://localhost:8080/)。镜像只将 `dist/web/` 复制到公开目录，不会复制源码、Python 服务、配置文件或压缩报告。生产环境在云负载均衡器或反向代理上配置 HTTPS，并发布完整的同一批构建产物。

已有 Nginx 时，把 `nginx.conf` 的 `server` 配置放入 HTTP 配置中，将 `root` 改为上传目录，再运行 `nginx -t` 验证后重载。这里使用官方镜像提供的 `gzip_static` 模块；其他发行版可用 `nginx -V` 确认包含 `--with-http_gzip_static_module`。

配置会为接受 gzip 的请求读取同名 `.gz`，不支持时发送原文件。`gzip_vary on` 设置 `Vary: Accept-Encoding`，`gzip_proxied any` 允许带代理 `Via` 头的请求使用压缩。WASM 响应类型为 `application/wasm`，PCK 为 `application/octet-stream`。这些行为依据 [Nginx gzip_static 文档](https://nginx.org/en/docs/http/ngx_http_gzip_static_module.html) 和 [gzip_vary 文档](https://nginx.org/en/docs/http/ngx_http_gzip_module.html#gzip_vary)。

当前文件名没有内容指纹，因此统一使用 `ETag` 和 `Cache-Control: public, max-age=0, must-revalidate`。浏览器可缓存内容，但再次访问需要验证版本；不要对这些固定文件名强制配置一年不可变缓存。更新时采用完整目录切换或重新部署镜像，避免分批覆盖造成 HTML、JS、WASM 和 PCK 版本混用。CDN 同样需要尊重这些响应头及编码协商，并在发布时清理旧版本缓存。

默认 Nginx 配置仅使用 gzip，不要求 Brotli 模块。若所用 Nginx 已安装并加载兼容的 Brotli static 模块，可在 `server` 中增加 `brotli_static on;`，继续保留 gzip 和原文件回退；安装方式取决于镜像与版本，参见 [Nginx Brotli 模块说明](https://docs.nginx.com/nginx/admin-guide/dynamic-modules/brotli/)。直接在不带模块的官方镜像中添加该指令会启动失败。

## 对象存储 / CDN

普通对象存储通常不会因为存在 `game.wasm.gz` 就自动用它响应 `game.wasm`。选择平台支持的方式：

- 上传原文件，启用 CDN 的 gzip / Brotli 自动压缩，并确认规则覆盖 `.wasm`、`.pck` 和 JavaScript，而非只压缩 HTML。此方式不需要上传压缩副本。
- 使用 CDN 的预压缩资源协商功能，为原 URL 配置 `.gz` / `.br` 副本、正确的 `Content-Encoding`、原文件 MIME 和 `Vary: Accept-Encoding`；保留原件供不支持压缩的客户端回退。
- 如果平台仅支持对象元数据，也可把 gzip 字节存到原资源键（如 `game.wasm`），设置 `Content-Encoding: gzip`、`Content-Type: application/wasm`。这不是自动协商，访问者必须支持该编码；需要兼容无压缩客户端时，应使用前两种方式。PCK 的 MIME 为 `application/octet-stream`。

不要只上传 `.gz` / `.br` 然后修改 Godot 加载 URL，也不要重命名压缩文件而省略 `Content-Encoding`。只有响应头和实际字节编码一致，浏览器才能正确解压。对象存储、CDN 的最大可压缩文件尺寸和支持的 MIME 可能有额外限制，应实际检查大 WASM 请求。

## 验证网络传输与内容

以下以当前导出文件名为例，在部署后检查原资源 URL（Windows PowerShell 可将 `curl` 换为 `curl.exe`）。本地预览用 `http://localhost:8080/`，当前云主机用 `https://106.12.81.171:80/` 并加 `-k`：

```sh
curl -I -H 'Accept-Encoding: gzip' 'http://localhost:8080/index.wasm'
curl -I -H 'Accept-Encoding: identity' 'http://localhost:8080/index.wasm'
curl -I -H 'Accept-Encoding: gzip' 'http://localhost:8080/index.pck'
```

第一条应包含 `Content-Encoding: gzip`、`Content-Type: application/wasm`、`Vary: Accept-Encoding`、`ETag` 和上述 `Cache-Control`；第二条应无 `Content-Encoding`，且 `Content-Length` 对应原件。启用 Brotli 后再以 `Accept-Encoding: br` 检查 `Content-Encoding: br`。不要用直接访问 `.gz` 文件的结果判断原 URL 的压缩是否生效。

本地校验应将每个 gzip / Brotli 副本解压，再与同目录原文件比较 SHA-256。也可以下载浏览器实际解压后的结果进行核对：

```sh
curl --compressed -o received.wasm 'http://localhost:8080/index.wasm'
```

在 PowerShell 中执行 `Get-FileHash -Algorithm SHA256 received.wasm` 和 `Get-FileHash -Algorithm SHA256 'dist/web/index.wasm'`，两者应一致。使用已有导出目录时，将这里的 `index.wasm` 换成实际文件名。`curl --compressed` 只能协商其自身支持的编码；Brotli 验证需要带 Brotli 支持的 curl。浏览器开发者工具的 Network 面板中同时检查 `Content-Encoding`、传输大小和资源大小，再启动游戏检查加载结果。

## 联机服务

此容器仅提供静态游戏页面，不启动或代理 Python 联机服务。匹配服务继续独立运行在 `8001` 端口；HTTPS 页面应连接可用的 `wss://` 地址，在云网关或单独反向代理中配置 WebSocket Upgrade 转发到该服务，并在游戏大厅填写对应地址。不要将线上地址设为 `127.0.0.1`，那会指向访问者的机器。

当前 Web 导出关闭线程，因此这里没有添加 COOP / COEP 隔离头。如果日后切换多线程模板，再按该模板要求配置隔离头及跨域资源。
