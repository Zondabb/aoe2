## In-process AI for local matches and the embedded gateway fallback.
## The Python rules service uses the same production and combat policy.
class_name AiDirector
extends Node

enum Phase { ECO, BOOM, ATTACK, DEFEND }

const TICK_INTERVAL := 0.5

const AiBlackboardScript := preload("res://scripts/systems/ai/ai_blackboard.gd")
const AiRunContextScript := preload("res://scripts/systems/ai/ai_run_context.gd")
const AiDecisionLogScript := preload("res://scripts/systems/ai/ai_decision_log.gd")
const AiEconomyManagerScript := preload("res://scripts/systems/ai/ai_economy_manager.gd")
const AiBuildManagerScript := preload("res://scripts/systems/ai/ai_build_manager.gd")
const AiProductionManagerScript := preload("res://scripts/systems/ai/ai_production_manager.gd")
const AiArmyManagerScript := preload("res://scripts/systems/ai/ai_army_manager.gd")
const AiCombatManagerScript := preload("res://scripts/systems/ai/ai_combat_manager.gd")
const CivAiProfileScript := preload("res://scripts/data/civ_ai_profile.gd")
const ObservationStoreScript := preload("res://scripts/ai_gateway/observation_store.gd")

var match_state: MatchState
var entities: Node2D
var ai_civ: CivDef
var profile: CivAiProfile
var ai_team: Enums.Team = Enums.Team.AI
var enemy_team: Enums.Team = Enums.Team.PLAYER
var team_label: String = "AI"
var director_phase: Phase = Phase.ECO
var match_time := 0.0
var enabled := true
var decision_log: AiDecisionLog

var _tick_accum := 0.0
var _next_build_slot := 0
var _blackboard: AiBlackboard
var _ctx: AiRunContext
var _progression := preload("res://scripts/systems/ai/ai_progression_manager.gd").new()
var _economy := AiEconomyManagerScript.new()
var _build := AiBuildManagerScript.new()
var _production := AiProductionManagerScript.new()
var _army := AiArmyManagerScript.new()
var _combat := AiCombatManagerScript.new()
var _scout := preload("res://scripts/systems/ai/ai_scout_manager.gd").new()
var _previous_phase: Phase = Phase.ECO


func setup(
	state: MatchState,
	entities_root: Node2D,
	civ: CivDef,
	ai_side: Enums.Team = Enums.Team.AI,
	enemy_side: Enums.Team = Enums.Team.PLAYER,
	label: String = "",
	shared_log: AiDecisionLog = null,
	defer_evaluate: bool = true
) -> void:
	match_state = state
	entities = entities_root
	ai_civ = civ
	profile = CivAiProfileScript.for_civ(civ)
	ai_team = ai_side
	enemy_team = enemy_side
	team_label = label if not label.is_empty() else ("Player" if ai_side == Enums.Team.PLAYER else "AI")
	director_phase = Phase.ECO
	match_time = 0.0
	_tick_accum = 0.0
	_next_build_slot = 0
	_previous_phase = Phase.ECO
	_scout.reset()
	_army.reset()
	enabled = true
	decision_log = shared_log if shared_log != null else AiDecisionLogScript.new()
	_blackboard = AiBlackboardScript.new()
	_ctx = AiRunContextScript.new()
	_bind_context()
	set_process(false)
	decision_log.log(0.0, team_label, "SETUP", "AI 已启动 (%s)" % (civ.id if civ != null else "unknown"))
	if defer_evaluate:
		call_deferred("evaluate")


func stop() -> void:
	if enabled and decision_log != null:
		decision_log.log(match_time, team_label, "STOP", "AI 已停止")
	enabled = false
	set_process(false)


func evaluate() -> void:
	if not enabled or match_state == null or entities == null:
		return
	if match_state.winner != -1:
		stop()
		return

	_blackboard.refresh(
		match_state,
		entities,
		ai_team,
		enemy_team,
		match_time,
		profile.defend_radius if profile != null else 20.0,
	)
	_bind_context()
	_update_phase()
	_ctx.phase = director_phase

	_economy.assign_builders(_ctx)
	_progression.tick(_ctx, _build)

	match director_phase:
		Phase.ECO:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
		Phase.BOOM:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
		Phase.ATTACK:
			if match_state.progression_enabled: _build.tick(_ctx)
			_production.tick(_ctx, _build)

		Phase.DEFEND:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
	_tick_army()
	_economy.assign_gatherers(_ctx)
	_progression.tick_technologies(_ctx)
	_scout.tick(_ctx)


func evaluate_capture(tick: int) -> Dictionary:
	if not enabled or match_state == null or entities == null:
		return {"commands": [], "debug": []}
	if match_state.winner != -1:
		return {"commands": [], "debug": []}

	_blackboard.refresh(
		match_state,
		entities,
		ai_team,
		enemy_team,
		match_time,
		profile.defend_radius if profile != null else 20.0,
	)
	_bind_context()
	_update_phase()
	_ctx.phase = director_phase
	_ctx.begin_capture(tick)

	_economy.assign_builders(_ctx)
	_progression.tick(_ctx, _build)

	match director_phase:
		Phase.ECO:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
		Phase.BOOM:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
		Phase.ATTACK:
			if match_state.progression_enabled: _build.tick(_ctx)
			_production.tick(_ctx, _build)

		Phase.DEFEND:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)

	_tick_army()
	_economy.assign_gatherers(_ctx)
	_progression.tick_technologies(_ctx)
	_scout.tick(_ctx)
	_next_build_slot = _ctx.next_build_slot
	return _ctx.end_capture()


func evaluate_from_observation(tick: int, observation: Dictionary) -> Dictionary:
	if not enabled or match_state == null or entities == null:
		return {"commands": [], "debug": []}
	if match_state.winner != -1:
		return {"commands": [], "debug": []}

	var store := ObservationStoreScript.new()
	store.load_from_dict(observation)
	store.apply_to_blackboard(_blackboard, ai_team, enemy_team)
	_bind_context()
	_update_phase()
	_ctx.phase = director_phase
	_ctx.begin_capture(tick)

	_economy.assign_builders(_ctx)
	_progression.tick(_ctx, _build)

	match director_phase:
		Phase.ECO:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
		Phase.BOOM:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)
		Phase.ATTACK:
			if match_state.progression_enabled: _build.tick(_ctx)
			_production.tick(_ctx, _build)

		Phase.DEFEND:
			_build.tick(_ctx)
			_production.tick(_ctx, _build)

	_tick_army()
	_economy.assign_gatherers(_ctx)
	_progression.tick_technologies(_ctx)
	_scout.tick(_ctx)
	_next_build_slot = _ctx.next_build_slot
	return _ctx.end_capture()


func _bind_context() -> void:
	_ctx.match_state = match_state
	_ctx.entities = entities
	_ctx.civ = ai_civ
	_ctx.profile = profile
	_ctx.team = ai_team
	_ctx.enemy_team = enemy_team
	_ctx.blackboard = _blackboard
	_ctx.decision_log = decision_log
	_ctx.team_label = team_label
	_ctx.phase = director_phase
	_ctx.next_build_slot = _next_build_slot


func _tick_army() -> void:
	if director_phase not in [Phase.ATTACK, Phase.DEFEND]:
		return
	var engaged: Dictionary = _combat.tick_army(_ctx)
	if director_phase == Phase.DEFEND:
		_army.rally_to_base(_ctx, engaged)
	else:
		_army.rally(_ctx, engaged)


func _update_phase() -> void:
	if profile == null:
		return
	# Answer raids in ECO and BOOM too; surviving troops defend before attacking.
	if _blackboard.threat_near_base:
		_set_phase(Phase.DEFEND)
		return
	var military_ready := (
		_blackboard.military_count >= profile.military_attack_count
		or match_time >= profile.attack_time_seconds
	)
	if director_phase == Phase.ATTACK:
		return
	if director_phase == Phase.DEFEND:
		_set_phase(Phase.ATTACK if military_ready else Phase.BOOM)
		return
	if military_ready:
		_set_phase(Phase.ATTACK)
		return
	var eco_ready := (
		_blackboard.villager_count >= profile.villager_target
		or _blackboard.food >= profile.high_food_stockpile
	)
	if director_phase == Phase.ECO and eco_ready:
		_set_phase(Phase.BOOM)


func _set_phase(new_phase: Phase) -> void:
	if director_phase != new_phase:
		_log_phase_change(new_phase)
		director_phase = new_phase

func _log_phase_change(new_phase: Phase) -> void:
	if decision_log == null:
		return
	decision_log.log(
		match_time,
		team_label,
		"PHASE",
		"%s → %s (村民=%d 军队=%d 食物=%d)"
		% [
			_phase_name(_previous_phase),
			_phase_name(new_phase),
			_blackboard.villager_count,
			_blackboard.military_count,
			_blackboard.food,
		]
	)
	_previous_phase = new_phase


func _phase_name(value: Phase) -> String:
	match value:
		Phase.ECO:
			return "ECO"
		Phase.BOOM:
			return "BOOM"
		Phase.ATTACK:
			return "ATTACK"
		Phase.DEFEND:
			return "DEFEND"
		_:
			return "?"


func _process(delta: float) -> void:
	if not enabled or match_state == null:
		return
	if match_state.winner != -1:
		stop()
		return
	match_time += delta
	_tick_accum += delta
	if _tick_accum < TICK_INTERVAL:
		return
	_tick_accum = 0.0
	_next_build_slot = _ctx.next_build_slot
	evaluate()
	_next_build_slot = _ctx.next_build_slot


func nearest_hostile_in_radius(unit: Node2D, radius: float) -> Node2D:
	return _combat.nearest_hostile_in_radius(unit, entities, enemy_team, radius)
