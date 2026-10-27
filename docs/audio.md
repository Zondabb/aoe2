# 原版音效

`add_audio` 分支使用本机原版 AoE2 HD 资源中的 WAV，保留原始录音。导出的精选资源随游戏打包，运行和导出时不需要原版安装目录或 Python。

- 菜单按钮、操作失败和建筑选择。
- 中国、条顿村民与军队的选择、移动、攻击、停止、采集与建造回应。一组单位仅一人回应，AI 指令不会触发玩家确认语音。
- 屏幕内且当前可见的战斗、死亡、伐木、采矿、农作与施工音效。
- 己方生产、建造完成、升级、受袭和胜负提示；离开画面也能收到己方提示。

主菜单右上方和对局右上方提供「音效」开关与音量滑块。修改保存在 `user://audio_settings.cfg`，重新启动后保留。默认值由 `data/game_settings.cfg` 的 `[audio]` 中 `volume=0.8`、`muted=false` 指定。

音频是本地表现，不改变战斗、寻路、采集、随机数或联机协议。联机客端根据同步的动画和生命值播放；开局、读档和首次快照不会播放整支初始军队的生产提示。声音使用独立通道与播放数量限制；游戏加速不改变音高。

资源 ID、来源校验和及重新导出步骤见 [音效导出工具](../tools/audio_export/README.md)。当前内容包含音效和单位语音，未加入背景音乐。

专项验证（使用 Godot 4.7 控制台程序，在仓库根目录运行）：

```powershell
Godot_console.exe --headless --path . --script res://tests/run_game_audio.gd
Godot_console.exe --headless --path . --script res://tests/run_interaction_audio.gd
Godot_console.exe --headless --path . --script res://tests/run_world_audio.gd
python -m unittest discover -s tools/audio_export/tests -v
```
