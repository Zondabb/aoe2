extends SceneTree
## Original ranges, actual launches, arrow poses, and replicated weapon profiles.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const LandSupport := preload("res://scripts/systems/land_support.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const ImpactTests := preload("res://tests/test_projectile_impact.gd")
const Observations := preload("res://scripts/ai_gateway/observation_builder.gd")
const Decisions := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE := preload("res://scenes/entities/projectile_view.tscn")
const CIV := preload("res://data/civs/chinese.tres")
const STEP := 1.0 / 60.0

var checks := 0
var failures: Array[String] = []
var world: Node2D
var state: MatchState


func _initialize() -> void:
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)


func _fixture() -> void:
	if is_instance_valid(world):
		world.free()
	Registry.clear()
	Events.clear()
	Collision.clear_map_bounds()
	world = Node2D.new()
	root.add_child(world)
	state = MatchState.new()
	state.setup_defaults()
	state.population_cap[0] = 100
	state.population_cap[1] = 100


func _unit(id: StringName, at: Vector2, side := Enums.Team.PLAYER) -> UnitAgent:
	var entity := UNIT.instantiate() as UnitAgent
	entity.def = Catalog.get_unit(id)
	entity.team = side
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	world.add_child(entity)
	entity.set_physics_process(false)
	return entity


func _building(id: StringName, at: Vector2, side := Enums.Team.PLAYER, ghost := false) -> BuildingAgent:
	var entity := BUILDING.instantiate() as BuildingAgent
	entity.def = Catalog.get_building(id)
	entity.team = side
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	entity.is_placement_ghost = ghost
	world.add_child(entity)
	entity.set_process(false)
	entity.set_physics_process(false)
	return entity


func _shots() -> Array[ProjectileAgent]:
	var result: Array[ProjectileAgent] = []
	for child in world.get_children():
		if child is ProjectileAgent and not child.is_queued_for_deletion():
			result.append(child)
	return result


func _shoot(weapon: UnitDef, origin: Vector2, aim: Vector2) -> ProjectileAgent:
	var shot := PROJECTILE.instantiate() as ProjectileAgent
	world.add_child(shot)
	shot.setup(origin, aim, weapon, Enums.Team.PLAYER)
	shot.set_physics_process(false)
	return shot


func _support_tick() -> void:
	var support := LandSupport.new()
	world.add_child(support)
	support.set_process(false)
	support.setup(state, world)
	support._process(0.25)
	support.free()


func _test_source_ranges() -> void:
	for id: StringName in [&"archer", &"crossbowman", &"arbalest", &"chu_ko_nu"]:
		var weapon := Catalog.get_unit(id)
		var expected := 20.0 if id in [&"crossbowman", &"arbalest"] else 16.0
		check(weapon != null and weapon.is_ranged, "%s has a ranged definition" % id)
		if weapon == null:
			continue
		check(is_equal_approx(weapon.attack_range, expected), "%s converts original maximum range once" % id)
		check(is_equal_approx(weapon.minimum_attack_range, float(Catalog.unit_record(id).min_range) * 4.0), "%s retains its original minimum range" % id)
		check(is_equal_approx(weapon.projectile_speed, 28.0), "%s uses original seven-tile arrow speed at map scale" % id)
		check(weapon.projectile_launch_height > 0.0, "%s launch height is separate from ground position" % id)
		check(weapon.projectile_flight_sheet == "res://assets/sprites/projectiles/arrow", "%s uses the extracted original arrow" % id)
	for id: StringName in [&"town_center", &"watch_tower", &"guard_tower", &"keep", &"castle"]:
		var weapon := Catalog.building_weapon(id)
		check(weapon != null, "%s exposes an authoritative building weapon" % id)
		if weapon == null:
			continue
		var expected := 24.0 if id == &"town_center" else 32.0
		check(is_equal_approx(weapon.attack_range, expected), "%s converts original maximum range once" % id)
		check(is_equal_approx(weapon.minimum_attack_range, float(Catalog.building_record(id).min_range) * 4.0), "%s retains original blind spot" % id)
		check(is_equal_approx(weapon.projectile_speed, 28.0) and weapon.projectile_launch_height > 0.0, "%s uses original arrow speed and elevated launch" % id)
	check(Catalog.building_weapon(&"house") == null, "a house does not acquire a defensive weapon")
	check(Catalog.get_unit(&"mangonel").attack_range == 28.0, "existing siege range is not scaled twice")


func _test_unit_range_and_launch() -> void:
	_fixture()
	var archer := _unit(&"archer", Vector2(5, 7))
	var target := _unit(&"militia", archer.sim_pos + Vector2(16, 0), Enums.Team.AI)
	check(archer._in_attack_range(target), "archer can attack at its exact four-tile maximum")
	target.sim_pos.x += 0.01
	check(not archer._in_attack_range(target), "archer cannot attack outside its maximum")
	archer.command_attack(target)
	for frame in 300:
		archer._physics_process(STEP)
		if not _shots().is_empty():
			break
	check(not _shots().is_empty(), "actual attack order chases and launches an arrow")
	check(archer._in_attack_range(target), "archer enters valid range before firing")
	if _shots().is_empty():
		return
	var shot := _shots()[0]
	check(shot._origin.is_equal_approx(archer.sim_pos), "arrow ground origin equals the firing unit's actual position")
	check(shot.sim_pos.is_equal_approx(shot._origin), "launch height does not shift ground position")
	check(shot.position.y < Iso.world_to_screen(shot.sim_pos).y, "arrow starts above the firing unit's ground position")
	check(shot.aim_pos.is_equal_approx(target.sim_pos), "ground aim remains the enemy position")
	var direction := (shot.aim_pos - shot._origin).normalized()
	shot._physics_process(0.1)
	check(shot.sim_pos.distance_to(shot._origin + direction * 2.8) <= 2.0 / 1024.0, "arrow advances at the original ground speed within two coordinate sub-units")
	var shooter_position := archer.sim_pos
	archer._physics_process(STEP)
	check(archer.sim_pos.is_equal_approx(shooter_position), "in-range archer holds position during its attack")


func _test_building_boundaries() -> void:
	for id: StringName in [&"town_center", &"watch_tower"]:
		var weapon := Catalog.building_weapon(id)
		for gap in [0.0, 0.01]:
			_fixture()
			var source := _building(id, Vector2.ZERO)
			_unit(&"militia", Vector2(weapon.attack_range + gap, 0), Enums.Team.AI)
			_support_tick()
			check(_shots().size() == (1 if gap == 0.0 else 0), "%s fires only at or inside maximum range (offset %.2f)" % [id, gap])
			if not _shots().is_empty():
				check(_shots()[0]._origin == source.sim_pos, "%s launch preserves building ground origin" % id)
				check(_shots()[0]._launch_height > 0.0, "%s arrow launches from an elevated weapon" % id)
	for distance in [3.99, 4.0]:
		_fixture()
		_building(&"watch_tower", Vector2.ZERO)
		_unit(&"militia", Vector2(distance, 0), Enums.Team.AI)
		_support_tick()
		check(_shots().size() == (1 if distance == 4.0 else 0), "tower respects its one-tile blind spot (distance %.2f)" % distance)
	_fixture()
	_building(&"town_center", Vector2.ZERO)
	_building(&"house", Vector2(10, 0), Enums.Team.AI, true)
	_support_tick()
	check(_shots().is_empty(), "defensive buildings never fire at placement ghosts")
	_fixture()
	_building(&"town_center", Vector2.ZERO, Enums.Team.PLAYER, true)
	_unit(&"militia", Vector2(10, 0), Enums.Team.AI)
	_support_tick()
	check(_shots().is_empty(), "a placement ghost never fires defensive arrows")


func _test_all_original_release_delays() -> void:
	for id: String in Catalog.arrow_projectiles().get("units", {}):
		_fixture()
		var shooter := _unit(StringName(id), Vector2.ZERO)
		var target := _unit(&"militia", Vector2(12, 0), Enums.Team.AI)
		check(shooter._combat_anim_duration(&"attack") >= shooter.def.attack_release_delay, "%s attack animation lasts until its original release frame" % id)
		shooter.command_attack(target)
		var elapsed := 0.0
		for frame in 180:
			shooter._physics_process(STEP)
			elapsed += STEP
			if not _shots().is_empty():
				break
		check(not _shots().is_empty(), "%s actually releases a projectile during its attack animation" % id)
		if not _shots().is_empty():
			check(elapsed + 0.0001 >= shooter.def.attack_release_delay, "%s does not launch before its original release delay" % id)
			check(_shots()[0].attacker_def == shooter.def, "%s launch keeps the original projectile profile" % id)


func _test_original_sheet_bounds() -> void:
	for name: String in ["arrow", "arrow_javelin", "arrow_shadow", "arrow_javelin_shadow"]:
		var base := "res://assets/sprites/projectiles/" + name
		var meta := Sprites.load_meta(base)
		var texture := Sprites.load_texture(base)
		check(not meta.is_empty() and texture != null, "%s original sheet is available" % name)
		if meta.is_empty() or texture == null:
			continue
		var count := int(meta.frame_count)
		var pitches := int(meta.frames_per_direction)
		check(count == int(meta.directions) * pitches, "%s has complete original direction/pitch groups" % name)
		for heading in int(meta.source_angle_count):
			var hours := 12.0 * float(heading) / float(meta.source_angle_count)
			for pitch in range(-1, pitches + 1):
				var frame := Sprites.projectile_frame_for_flight(hours, pitch, meta)
				var index := int(frame.index)
				check(index >= 0 and index < count, "%s heading %d pitch %d stays inside its own atlas" % [name, heading, pitch])
				if index < 0 or index >= count:
					continue
				var atlas := Sprites.atlas_frame_at(meta, texture, index)
				check(Rect2(Vector2.ZERO, texture.get_size()).encloses(atlas.region), "%s heading %d pitch %d uses a complete texture cell" % [name, heading, pitch])


func _test_direction_and_pitch() -> void:
	for sample in [
		{"hours": 12.0, "group": 15, "name": "north"},
		{"hours": 6.0, "group": 0, "name": "south"},
		{"hours": 3.0, "group": 8, "name": "east", "flip": true},
		{"hours": 9.0, "group": 8, "name": "west", "flip": false},
	]:
		var frame := Sprites.projectile_frame_for_flight(sample.hours, 5)
		check(int(frame.group) == sample.group, "%s uses the original arrow direction group" % sample.name)
		if sample.has("flip"):
			check(bool(frame.flip) == sample.flip, "%s applies original sprite mirroring" % sample.name)
		check(int(frame.index) == int(frame.group) * 11 + 5, "%s keeps pitch inside its direction group" % sample.name)
	_fixture()
	# Use a steep test arc so rising/falling tangents span distinct discrete poses;
	# the original shallow arrow arc can correctly round both to the level pose.
	var slope_weapon := Catalog.get_unit(&"archer").duplicate() as UnitDef
	slope_weapon.projectile_arc = 0.65
	var shot := _shoot(slope_weapon, Vector2.ZERO, Vector2(8, -8))
	# A level ground path separates arrow height from isometric ground projection.
	shot._launch_height = 0.0
	var epsilon := 0.001
	var ascending := (shot._screen_pos_for_progress(0.2 + epsilon).y - shot._screen_pos_for_progress(0.2 - epsilon).y) / (2.0 * epsilon)
	var descending := (shot._screen_pos_for_progress(0.8 + epsilon).y - shot._screen_pos_for_progress(0.8 - epsilon).y) / (2.0 * epsilon)
	check(ascending < 0.0 and descending > 0.0, "arrow trajectory has a rising and falling segment")
	check(shot._sequence_step(0.2) < shot._sequence_step(0.8), "arrow pitch follows rising versus falling trajectory slope")
	var low_pitch := shot._sequence_step(0.5)
	shot._launch_height = 500.0
	check(shot._sequence_step(0.5) > low_pitch, "same flight progress changes pitch when launch height changes the trajectory slope")
	var short_shot := _shoot(Catalog.get_unit(&"archer"), Vector2.ZERO, Vector2(1, -1))
	var poses := {}
	for index in 101:
		poses[short_shot._sequence_step(float(index) / 100.0)] = true
	check(poses.size() < 11, "a short flight does not mechanically play all eleven pitch poses")
	check(short_shot._sequence_step(0.0) != 0 or short_shot._sequence_step(1.0) != 10, "short-flight endpoints are selected from slope instead of fixed animation endpoints")


func _test_network_profiles() -> void:
	_fixture()
	var replica := PROJECTILE.instantiate() as ProjectileAgent
	replica.set_meta("network_replica", true)
	world.add_child(replica)
	for id: StringName in [&"archer", &"watch_tower", &"skirmisher", &"town_center"]:
		var weapon := Catalog.get_unit(id)
		if weapon == null:
			weapon = Catalog.building_weapon(id)
		var host := _shoot(weapon, Vector2(3, 4), Vector2(19, 4))
		host._physics_process(0.2)
		var payload: Dictionary = JSON.parse_string(JSON.stringify(host.network_presentation()))
		replica.apply_network_presentation(payload)
		check(replica.attacker_def != null and replica.attacker_def.id == id, "replica switches to %s source definition" % id)
		if replica.attacker_def != null:
			check(replica.attacker_def.projectile_flight_sheet == weapon.projectile_flight_sheet, "%s replica preserves arrow or javelin art" % id)
			check(replica.attacker_def.projectile_speed == weapon.projectile_speed, "%s replica preserves original projectile speed" % id)
			check(replica.attacker_def.projectile_arc == weapon.projectile_arc, "%s replica preserves trajectory profile" % id)
		check(replica.sim_pos.is_equal_approx(host.sim_pos) and replica.position.is_equal_approx(host.position), "%s replica matches both ground and visible trajectory" % id)
		check(is_equal_approx(replica._launch_height, host._launch_height), "%s replica retains launch height" % id)
		var host_texture := (host.get_node("Sprite") as Sprite2D).texture as AtlasTexture
		var replica_texture := (replica.get_node("Sprite") as Sprite2D).texture as AtlasTexture
		check(host_texture != null and replica_texture != null and host_texture.atlas == replica_texture.atlas and host_texture.region == replica_texture.region, "%s replica uses the host's exact direction and pitch frame" % id)
		var previous := replica.position
		replica._physics_process(10.0)
		check(replica.position == previous and not replica.is_queued_for_deletion(), "%s replica does not simulate local damage or expiry" % id)
		host.free()


func _test_ai_weapon_context() -> void:
	_fixture()
	var archer := _unit(&"archer", Vector2.ZERO)
	var tower := _building(&"watch_tower", Vector2(10, 0))
	var tc := _building(&"town_center", Vector2(-10, 0))
	check(Observations.serialize_entity(archer).combat.range == 16.0, "archer observation uses converted simulation distance")
	check(Observations.serialize_entity(tower).combat.range == 32.0, "tower observation uses its actual firing distance")
	check(Observations.serialize_entity(tower).combat.minimum_range == 4.0, "tower observation exposes its blind spot")
	check(Observations.serialize_entity(tc).combat.range == 24.0, "town center observation uses its actual firing distance")
	var catalog := Decisions._catalog(state, world, Enums.Team.PLAYER, CIV)
	var unit_records: Array = catalog.units.filter(func(item): return item.id == "archer")
	var building_records: Array = catalog.buildings.filter(func(item): return item.id == "town_center")
	check(unit_records.size() == 1 and unit_records[0].attack_range == 16.0 and unit_records[0].cooldown == archer.def.attack_cooldown, "AI unit catalog agrees with the live archer")
	check(building_records.size() == 1 and building_records[0].attack_range == 24.0 and building_records[0].minimum_range == 0.0, "AI building catalog agrees with live town center boundaries")


func _run() -> void:
	_test_source_ranges()
	_test_unit_range_and_launch()
	_test_building_boundaries()
	_test_all_original_release_delays()
	_test_original_sheet_bounds()
	_test_direction_and_pitch()
	_test_network_profiles()
	_test_ai_weapon_context()
	var impact_failures: Array[String] = ImpactTests.new().run()
	check(impact_failures.is_empty(), "existing arrow impact, miss, and non-homing behavior remains intact")
	for failure in impact_failures:
		check(false, "existing arrow impact regression: " + failure)
	if is_instance_valid(world):
		world.free()
	await process_frame
	print("Ranged combat: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
