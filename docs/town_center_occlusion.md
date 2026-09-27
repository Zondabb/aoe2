# 城镇中心遮挡与通行

城镇中心采用三层绘制：地面阴影（`z_index=-3`）、人物（默认 `0`）、建筑屋顶和支柱等实体（`1`）。选取框保留在 `-2`，血条与界面保留原有层级。

中国城镇中心的原图包含 SLP 导出的半透明黑色阴影。`player_color.gdshader` 根据原始纹理像素区分阴影与实体，两个 Sprite2D 共用同一张图、偏移和缩放，分别绘制；不新增或修改图片文件。不透明黑色属于实体，不会被当成阴影。条顿城镇中心没有内嵌阴影，保留地面椭圆。队伍换色、建筑放置预览和迷雾记忆均沿用分层材质。

`BuildingDef.blocks_movement` 默认开启，城镇中心单独关闭。导航、静态碰撞和局部避障允许人物穿过城镇中心或停留在内部；原来的 `4×4` 占地仍用于建筑放置、选取、资源交付和战斗距离。其他建筑的阻挡规则不变。此规则同时用于本地模拟和联机主机模拟，双方客户端应使用相同版本。

## 验证

从项目根目录使用 Godot 控制台程序运行以下专项脚本（受限环境可额外用 `--log-file` 指定项目 `.godot/` 中的绝对路径）：

```sh
godot --headless --path . --script res://tests/run_town_center_movement.gd
godot --headless --path . --script res://tests/run_town_center_occlusion.gd
godot --headless --path . --script res://tests/run_crowd_movement.gd
godot --headless --path . --script res://tests/run_fog_of_war.gd
godot --path . --rendering-method gl_compatibility --script res://tests/render_town_center_occlusion.gd
```

渲染测试需要真实图形后端，会逐像素检查前景人物标记无法覆盖屋顶、阴影无法覆盖人物，并输出 `.godot/town-center-occlusion.png`。无界面测试覆盖两种文明、右键移动到中心、横向/纵向/斜向穿越、其他建筑阻挡、队伍颜色、放置预览及迷雾记忆。

Godot 编辑器重新运行项目即可使用新逻辑。Web 版需按 [Web 发布说明](../deploy/web/README.md) 重新导出和发布。
