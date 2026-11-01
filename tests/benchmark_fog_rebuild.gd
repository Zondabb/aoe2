extends SceneTree
## FogOfWarService.rebuild() on the default map's 120 × 120 mask (480 tiles,
## 4-tile cells): moving vision sources of radius 16 split between both teams,
## every source moved before each rebuild. Reports the native kernel
## (aoe_sim GDExtension) and the GDScript path.
##   godot --headless --path . --script res://tests/benchmark_fog_rebuild.gd
const FogService := preload("res://scripts/systems/fog_of_war_service.gd")

class Source extends RefCounted:
	var team := 0
	var hp := 10.0
	var sim_pos := Vector2.ZERO
	var def: Variant = null
	func resolved_vision_radius() -> float:
		return 16.0

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var kernel: RefCounted = FogService._kernel
	for count in [100, 300, 500]:
		var sources: Array = []
		for i in count:
			var source := Source.new()
			source.team = i % 2
			source.sim_pos = Vector2(rng.randf_range(-230, 230), rng.randf_range(-230, 230))
			sources.append(source)
		var line := "FOG REBUILD sources=%d" % count
		for mode in ["native", "script"]:
			if mode == "native" and kernel == null: continue
			FogService._kernel = kernel if mode == "native" else null
			var fog := FogService.new()
			fog.setup_rect(Vector2(-240, -240), Vector2(240, 240), 4.0)
			fog.rebuild(sources)
			var total := 0
			for run in 30:
				for source in sources: source.sim_pos += Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))
				var started := Time.get_ticks_usec()
				fog.rebuild(sources)
				total += Time.get_ticks_usec() - started
			line += "  %s %.2f ms" % [mode, total / 30000.0]
		FogService._kernel = kernel
		print(line)
	quit(0)
