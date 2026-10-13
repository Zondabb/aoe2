extends SceneTree

const Controls := preload("res://scripts/ui/ai_autoplay_controls.gd")

class MockController extends Node:
	signal state_changed
	var state := {"enabled": false, "status": "off", "message": "", "available": true}
	var requests: Array[bool] = []
	func local_state() -> Dictionary:
		return state
	func request_local_enabled(value: bool) -> bool:
		requests.append(value)
		state.enabled = value
		state.status = "connecting" if value else "off"
		state_changed.emit()
		return true
	func update(next: Dictionary) -> void:
		state.merge(next, true)
		state_changed.emit()

var _failures := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(value: bool, description: String) -> void:
	_checks += 1
	if not value:
		_failures += 1
		push_error(description)


func _run() -> void:
	var match_root := Node2D.new()
	root.add_child(match_root)
	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	match_root.add_child(layer)
	var control := Controls.new()
	control.name = "AiAutoplayControls"
	control.size = Vector2(1280, 720)
	layer.add_child(control)
	await process_frame
	var checkbox := control.get_node("Panel/Row/AutoplayCheck") as CheckBox
	var label := control.get_node("Panel/Row/Status") as Label
	for icon_name in ["unchecked", "checked", "unchecked_disabled", "checked_disabled"]:
		var texture := checkbox.get_theme_icon(icon_name)
		_check(checkbox.has_theme_icon_override(icon_name) and texture != null and texture.get_size() == Vector2(18, 18), "%s 使用清晰可见的托管复选框图标" % icon_name)
	_check(checkbox.disabled and not checkbox.button_pressed, "初始化未创建 controller 时不可开启托管")
	var controller := MockController.new()
	controller.name = "PlayerAiControl"
	match_root.add_child(controller)
	await process_frame
	await process_frame
	_check(not checkbox.disabled and not checkbox.button_pressed and label.text == "手动控制", "延迟绑定可用 controller，默认手动控制")
	_check(control.mouse_filter == Control.MOUSE_FILTER_IGNORE, "全屏 control 不吞地图鼠标")
	var panel := control.get_node("Panel") as Control
	_check(panel.position == Vector2(16, 36) and panel.size.y <= 35, "UI 位于资源栏下方且不覆盖联机状态或调试面板")
	for width in [640, 1280, 1920]:
		control.size.x = width
		await process_frame
		_check(panel.position.x >= 0 and panel.position.x + panel.size.x <= width, "托管控件在 %d 宽度内完整显示" % width)
	checkbox.button_pressed = true
	_check(controller.requests == [true] and checkbox.button_pressed and not checkbox.disabled and label.text == "正在连接…", "勾选向 controller 申请开启，连接中仍可取消")
	checkbox.button_pressed = false
	_check(controller.requests == [true, false] and label.text == "手动控制", "取消勾选向 controller 申请停止")
	controller.update({"enabled": true, "status": "active"})
	_check(checkbox.button_pressed and label.text == "托管中", "状态信号更新托管显示且不产生额外请求")
	_check(controller.requests.size() == 2, "权威状态刷新不触发 toggle 回传")
	controller.update({"status": "pending"})
	_check(checkbox.disabled and label.text == "等待主机确认…", "客端等待确认期间禁止连续点击")
	controller.update({"enabled": false, "status": "error", "message": "Python 服务连接失败：127.0.0.1:8765"})
	_check(not checkbox.disabled and not checkbox.button_pressed and label.text.contains("重试"), "连接失败取消选中并允许重试")
	_check(label.tooltip_text.contains("127.0.0.1:8765"), "错误详情提供真实服务地址")
	var game := root.get_node("GameSession")
	game.online_active = true
	controller.update({"status": "off"})
	_check(checkbox.tooltip_text.contains("主机") and checkbox.tooltip_text.contains("自己的"), "联机提示说明主机服务与自己的队伍")
	var screenshot_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot="):
			screenshot_path = argument.trim_prefix("--screenshot=")
	if not screenshot_path.is_empty():
		controller.update({"enabled": true, "status": "active"})
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(screenshot_path)
	controller.update({"enabled": false, "status": "ended", "available": false})
	_check(checkbox.disabled and not checkbox.button_pressed and label.text == "对局结束", "对局结束不能重开托管")
	game.online_active = false
	match_root.queue_free()
	await process_frame
	print("AI autoplay UI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
