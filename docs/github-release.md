# GitHub Windows 版本发布

仓库： https://github.com/Zondabb/aoe2

`.github/workflows/release.yml` 使用 Godot 4.7.1 与匹配的官方导出模板，
导入项目并导出 Windows x64 版本，将 EXE、PCK 和运行说明打包为 ZIP。
构建产物还包括 SHA256 校验文件。Python AI 服务和联机服务器不包含在包内。

## 首次验证

将工作流、导出配置、运行说明和本说明提交并推送到 GitHub 默认分支。
在仓库 Actions 页面选择 **Game Release → Run workflow**。
成功后在本次运行的 Artifacts 下载 `aoe2-windows-x64`，解压其中的游戏 ZIP，
启动 `aoe2.exe` 验证主菜单、单机对局与地图加载。手动运行只构建，不创建 Release。

## 发布版本

先确认需要发布的代码和素材都已提交，工作流已推送，且工作目录中希望包含的
改动已提交。标签只发布标签指向的提交，不包含本地未提交内容。

```powershell
git tag -a v0.1.0 -m "AoE2 RTS v0.1.0"
git push origin HEAD
git push origin v0.1.0
```

标签推送后，Actions 自动构建，成功后创建同名 GitHub Release 并上传
`aoe2-v0.1.0-windows-x64.zip` 和 `SHA256SUMS.txt`。
下载入口：https://github.com/Zondabb/aoe2/releases
以后使用新的版本标签，例如 `v0.1.1`。不要重复使用已经发布的标签。

用户需要解压整个 ZIP，保留 EXE 和 PCK 在同一目录，无需安装 Godot。
工作流使用 GitHub 自动提供的 `GITHUB_TOKEN`，无需额外配置密钥。
仓库或组织必须允许 GitHub Actions 运行及工作流写入 Releases。

## 常见失败

- 下载引擎或模板失败：检查 `GODOT_VERSION` 对应的官方 Release 和资源是否存在。
- 导出提示脚本或资源错误：查看 Import project / Export Windows x64 日志，
  确认依赖素材已提交（包括 Git LFS 文件）。
- 游戏缺少配置或地图：检查 Windows Desktop 的 include_filter；
  通过 FileAccess 读取的 JSON / CFG 需要明确包含。
- Release 创建失败：检查 Actions 权限，以及相同标签的 Release 是否已经存在。
  若构建已成功，可从该运行的 Artifacts 获取 ZIP 和校验文件，手动添加到已有 Release。

升级 Godot 时同步修改工作流中的版本，并用对应版本重新验证导出。
