# 单机存档与单位信息

单机对局右上角提供“保存游戏”“读取存档”和“主菜单”。保存时可输入名称创建新存档，也可选中已有存档；确认按钮会显示“覆盖存档”。选档窗口打开期间游戏暂停，关闭窗口后继续。

F5 将当前单机游戏保存到“快速存档”（再次按 F5 会覆盖该槽位）。F9 打开读档窗口。主菜单和单机设置页也可以读取存档，无需重新选择地图、文明和对手控制方式。

存档存放在 Godot 用户数据目录的 `saves` 文件夹内，以 JSON 文件保存。读档使用存档内的地图内容，因此导入地图文件移动或删除后仍可恢复。读取失败时会显示错误并保留当前页面或对局。联机对局不提供单机存档按钮。

存档保留双方资源与人口、单位位置及命令目标、受伤血量、采集携带资源、建筑施工、生产队列与原付款、时代和科技研究、飞行中的投射物、迷雾探索记录、镜头及 AI 运行状态。读档后这些系统继续模拟；AI 服务的 API Token 不写入存档，沿用当前设置。

水域与悬崖也会保存，读档后仍阻挡陆地移动和建筑放置。地形纹理及迷雾记忆会恢复，小地图继续隐藏未知区域。已消失但尚未重新观察的地形只保留记忆外观，不恢复碰撞。建筑等待有效出口的训练队列保持完成进度与人口预约。

左键点击视野中的敌方单位或建筑可以查看名称、当前/最大血量与基础战斗属性。敌方对象只供查看；框选维持选择己方单位，敌方对象离开视野或死亡后信息会自动清除。

验证命令（可按本机安装位置调整可执行文件路径）：

```powershell
$godot = "D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
& $godot --headless --path . --script tests/run_save_game.gd
& $godot --headless --path . --script tests/run_save_game_edges.gd
& $godot --headless --path . --script tests/run_save_game_ui.gd
& $godot --headless --path . --script tests/run_enemy_inspection.gd
& $godot --headless --path . --script tests/run_terrain_save.gd
```
