# 两个 Python AI 服务进行联机模型对战

每个 Python 进程加载一份模型配置，并监听不同端口。每个游戏客户端连接自己选择的服务，双方玩家各自勾选 AI 托管。模型名、模型地址与密钥仍只在 Python 端配置。

## 启动两个服务

在两个 PowerShell 终端中进入 `ai_service_python` 目录，分别执行：

```powershell
# 终端一：config.toml，例如本机 Qwen
.\.venv\Scripts\python.exe main.py --config .\config.toml --port 8765 --log-dir logs/qwen
```

```powershell
# 终端二：config.ds.toml，例如 DeepSeek
.\.venv\Scripts\python.exe main.py --config .\config.ds.toml --port 8766 --log-dir logs/deepseek
```

`--port` 明确区分监听端口，`--log-dir` 将每个服务的 `multi_agent.jsonl` 与 `llm.log` 分开保存，便于核对实际模型、角色计划、游戏命令和耗时。相对日志路径以选定配置文件所在目录为起点。也可以在各自配置的 `[service]` 下设置 `port` 和 `log_dir`。

默认配置的私有覆盖是 `config.local.toml`；第二份配置的私有覆盖为 `config.ds.local.toml`。命令行和环境变量仍优先于配置文件；如果两个终端继承相同的 `AOE2_LLM_MODEL` 或 `AOE2_LLM_BASE_URL`，它们可能覆盖两份不同配置。检查各自启动日志的 `llm_model`，确认使用了预期模型。

`start_qwen3_proxy.ps1 -ConfigPath .\config.ds.toml` 也会读取所选文件的监听端口，不再默认覆盖为 8765 或关闭占用端口的另一个服务。该脚本采用本机模型的低并发设置；远程模型可以直接使用上述 `main.py` 启动方式。

## 联机中选择双方地址

进入联机对局后，每位玩家展开资源栏下方的 **AI 地址**：

| 队伍 | Python AI 服务地址 |
| --- | --- |
| 玩家 A 的本机服务 | `http://127.0.0.1:8765` |
| 玩家 B 可访问的云端服务 | `https://ai.example.com` |

分别点击应用，再由两位玩家各自勾选 **AI 托管（Python LLM）**。两队将使用各自的 Python 服务进行侦察、经济、建造、科技和作战。地址可以在托管前配置；托管过程中更换地址会停止旧会话并重连该队，另一队保持运行。连接状态和失败原因会显示在对应队伍行。

地址由各玩家的游戏进程访问。127.0.0.1 指填写地址的玩家电脑；也可以填写自己能访问的局域网或云端服务地址。

也可以预先在游戏的 `data/game_settings.cfg` 或已有用户覆盖文件中配置：

```ini
[ai]
service_url="http://127.0.0.1:8765"
protocol="v2_chat"
multi_agent_enabled=true
use_local_embedded=false
team_0_service_url="http://127.0.0.1:8765"
team_1_service_url="http://127.0.0.1:8766"
team_0_api_token=""
team_1_api_token=""
```

队伍地址留空时回退到 `service_url`。队伍访问凭据留空时回退到游戏的 `api_token`；如两服务分别设置了 `[service].api_token`，就在各自的游戏配置中填写。这里只填写访问 Python 服务的凭据；模型 API 密钥继续留在服务端。访问凭据不会同步给客端。

## 比较结果

记录两边实际模型与生成参数、胜负和对局时间，并对照各自日志查看计划是否合法、是否被采用、命令是否执行。使用同一地图、游戏速度和规则，再交换两队模型与文明复测，可以减少起始位置和文明差异的影响。`max_tokens`、模型超时和规划调用额度也应记录或统一。

## 验证

双服务联调会创建两个临时 Python 服务、两个不同模型名的本机模拟上游、联机中继和两个 Godot 客户端，检查模型与队伍路由、换址隔离及取消托管，不读取上述用户配置或调用付费模型：

```powershell
# 仓库根目录，替换为本机 Godot 控制台程序
.\ai_service_python\.venv\Scripts\python.exe tools/test_dual_ai_services_e2e.py --godot '<Godot控制台程序路径>'
```
