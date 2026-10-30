extends SceneTree

const Controls := preload("res://scripts/ui/ai_autoplay_controls.gd")

class MockController extends Node:
	signal state_changed
	var state := {"enabled": false, "status": "off", "message": "", "available": true}
	var requests: Array[bool] = []
	var routes := {0: "http://127.0.0.1:8765", 1: "http://127.0.0.1:8766"}
	var route_requests: Array = []
	var remote_state := {"enabled": false, "status": "off", "message": "", "available": true}
	func capture_states() -> Dictionary:
		return {"0": state, "1": remote_state}
	func team_service_url(team: int) -> String:
		return routes.get(team, "")
	func request_team_service_url(team: int, url: String) -> bool:
		route_requests.append([team, url])
		var network := get_node("/root/NetworkSession")
		if not network.is_host() or not url.begins_with("http://"):
			return false
		routes[team] = url.trim_suffix("/")
		state_changed.emit()
		return true
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
	var network := root.get_node("NetworkSession")
	game.online_active = true
	game.online_team = 0
	network.team = 0
	network.host_team = 0
	controller.update({"status": "off"})
	_check(checkbox.tooltip_text.contains("主机") and checkbox.tooltip_text.contains("自己的"), "联机提示说明主机服务与自己的队伍")
	var settings := control.get_node("Panel/Row/ServiceSettings") as Button
	var service_panel := control.get_node("ServicePanel") as Control
	_check(settings.visible and not service_panel.visible, "联机服务地址默认折叠，减少地图遮挡")
	settings.button_pressed = true
	await process_frame
	var host_row := control.get_node("ServicePanel/Contents/Team0") as Control
	var guest_row := control.get_node("ServicePanel/Contents/Team1") as Control
	var host_address := host_row.get_node("Address") as LineEdit
	var guest_address := guest_row.get_node("Address") as LineEdit
	var note := control.get_node("ServicePanel/Contents/Note") as Label
	_check(service_panel.visible and host_row.visible and guest_row.visible and host_address.editable and guest_address.editable, "主机可分别配置双方的 Python 服务地址")
	_check(host_address.text.ends_with(":8765") and guest_address.text.ends_with(":8766"), "双方独立显示实际服务地址")
	_check(note.text.contains("127.0.0.1") and note.text.contains("主机"), "说明服务地址从主机访问")
	controller.remote_state.merge({"status": "error", "message": "连接失败：8766"}, true)
	controller.update({"status": "off"})
	_check(control.get_node("ServicePanel/Contents/Team1Status").text.contains("8766"), "主机能看到客端队伍的服务连接失败原因")
	guest_address.text = "http://127.0.0.1:8877/"
	guest_address.text_changed.emit(guest_address.text)
	controller.update({"status": "connecting"})
	_check(guest_address.text.ends_with(":8877/"), "托管状态刷新保留尚未应用的地址编辑")
	guest_row.get_node("Apply").pressed.emit()
	_check(controller.routes[1] == "http://127.0.0.1:8877" and guest_address.text.ends_with(":8877") and note.text.contains("已应用"), "应用时保存所选队伍的地址并显示标准化地址")
	host_address.text = "invalid"
	host_row.get_node("Apply").pressed.emit()
	_check(controller.routes[0].ends_with(":8765") and note.text.contains("地址无效"), "地址拒绝时保留实际配置并显示失败原因")
	for width in [480, 640, 1280]:
		control.size.x = width
		await process_frame
		_check(service_panel.position.x + service_panel.size.x <= width, "地址面板在 %d 宽度内完整显示" % width)
	game.online_team = 1
	network.team = 1
	controller.update({"status": "off"})
	_check(not host_row.visible and guest_row.visible and not guest_address.editable and not guest_row.get_node("Apply").visible, "客端只看自己实际地址，不能编辑或应用地址")
	_check(not checkbox.disabled and not checkbox.button_pressed, "客端仍能开关自己的 AI 托管")
	controller.routes[1] = "http://host.example:8890"
	controller.update({"status": "off"})
	_check(guest_address.text == "http://host.example:8890", "客端显示主机最新同步的服务地址")
	network.host_team = 1
	controller.update({"status": "off"})
	_check(host_row.visible and guest_row.visible and host_address.editable and guest_address.editable, "随机选择队伍 2 为主机时可配置双方服务")
	host_address.text = "http://127.0.0.1:8891"
	host_row.get_node("Apply").pressed.emit()
	_check(controller.routes[0].ends_with(":8891"), "队伍 2 主机可应用队伍 1 的服务地址")
	network.team = 0
	game.online_team = 0
	controller.update({"status": "off"})
	_check(host_row.visible and not guest_row.visible and not host_address.editable, "队伍 1 客端没有主机配置权限")
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
	game.online_team = 0
	network.leave()
	match_root.queue_free()
	await process_frame
	print("AI autoplay UI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
