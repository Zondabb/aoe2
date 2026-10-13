extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func save_config(path: String, values: Dictionary, section: String = "multiplayer") -> void:
	var config := ConfigFile.new()
	for key in values:
		config.set_value(section, key, values[key])
	check(config.save(path) == OK, "save temporary configuration")

func _run() -> void:
	var settings: GDScript = load("res://scripts/core/game_settings.gd")
	var session := root.get_node("GameSession")
	var original_url: String = session.online_server_url
	var paths: Array[String] = ["res://.godot/mp-default-test.cfg", "res://.godot/mp-external-test.cfg", "res://.godot/mp-user-test.cfg"]
	save_config(paths[0], {"host": "192.168.1.20", "port": 8001, "use_tls": false})
	save_config(paths[1], {"host": "192.168.1.30", "port": 18001})
	save_config(paths[2], {"port": 19001})
	var merged: Dictionary = settings.load_multiplayer_settings(paths[0], paths[2], paths[1])
	check(merged.host == "192.168.1.30" and merged.port == 19001 and not merged.use_tls, "user overrides per field while executable config overrides packaged host")
	check(settings.multiplayer_server_url(merged) == "ws://192.168.1.30:19001/ws", "IP and port form the WebSocket endpoint")
	save_config(paths[2], {"model": "example"}, "ai")
	merged = settings.load_multiplayer_settings(paths[0], paths[2], paths[1])
	check(merged.host == "192.168.1.30" and merged.port == 18001, "AI-only user config preserves multiplayer defaults")
	merged = settings.load_multiplayer_settings(paths[0], "res://.godot/mp-missing.cfg", "res://.godot/mp-missing.cfg")
	check(merged.host == "192.168.1.20" and merged.port == 8001, "missing overrides preserve packaged settings")
	check(settings.multiplayer_server_url({"host": "games.example.com", "port": 443, "use_tls": true}) == "wss://games.example.com:443/ws", "TLS proxy uses configured hostname and port")
	check(settings.multiplayer_server_url({"host": "2001:db8::1", "port": 8001}) == "ws://[2001:db8::1]:8001/ws", "bare IPv6 is bracketed once")
	check(settings.multiplayer_server_url({"host": "[::1]", "port": 8001}) == "ws://[::1]:8001/ws", "bracketed IPv6 is accepted")
	check(settings.multiplayer_server_url({"host": "127.0.0.1", "port": "18001"}) == "ws://127.0.0.1:18001/ws", "quoted numeric port is supported")
	for host in ["", "ws://192.168.1.2", "example.com/path", "name@host", "host:8001"]:
		check(settings.normalize_multiplayer_settings({"host": host}).host == "127.0.0.1", "invalid host falls back: " + host)
	for port in [0, -1, 65536, "abc", 8001.5]:
		check(settings.normalize_multiplayer_settings({"port": port}).port == 8001, "invalid port falls back: " + str(port))
	var invalid := FileAccess.open(paths[2], FileAccess.WRITE)
	invalid.store_string("[multiplayer]\nhost=ws://invalid\n")
	invalid.close()
	merged = settings.load_multiplayer_settings(paths[0], paths[2], paths[1])
	check(merged.host == "192.168.1.30" and merged.port == 18001, "invalid override does not discard valid lower-priority config")
	var packaged := ConfigFile.new()
	check(packaged.load(settings.RES_PATH) == OK and packaged.has_section("multiplayer"), "shipped configuration exposes the multiplayer section")
	var applied: Dictionary = settings.apply_multiplayer_to_game_session()
	check(session.online_server_url == settings.multiplayer_server_url(applied), "configuration is applied to GameSession at startup")
	session.online_server_url = settings.multiplayer_server_url({"host": "192.168.1.30", "port": 18001})
	var lobby: Control = load("res://scripts/ui/online_lobby.gd").new()
	root.add_child(lobby)
	check(lobby.get_node("ServerUrl").text == "ws://192.168.1.30:18001/ws", "real lobby is prefilled with the configured server endpoint")
	lobby.free()
	session.online_server_url = original_url
	for path in paths:
		check(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK, "remove temporary configuration")
	print("MULTIPLAYER SETTINGS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
