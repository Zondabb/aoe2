extends RefCounted

## A bounded input pipeline. Both peers simulate commands only at their
## committed execution frame and render normal physics interpolation.
const FRAME := 3
const RATE := 30.0
const MAX_PENDING := 256
const INPUT_DELAY_SECONDS := 0.1 # Real seconds, independent of match speed.
var network: Node
var plans: Dictionary = {}
var commits: Dictionary = {}
var completed: Dictionary = {}
var confirmations: Dictionary = {}
var pending: Array = []
var rejected: Array = []
var planned_tick := 0
var committed_tick := 0
var ready_tick := 0
var _startup_plan_tick := 0
var _needs_plan_ack := true
var _last_sent_timing: Dictionary = {}
var _last_frame_speed := -1.0
var input_delay_ticks := FRAME
var _last_manual_target := {0: 0, 1: 0}
var delay_schedule: Array = []
var clock_offset_usec := 0.0
var rtt_usec := 40000.0
var clock_ready := false
var _clock_samples: Array = []
var _clock_resume_usec := 0
var _probe_at := 0
var _nonce := 0
var _probes: Dictionary = {}
var _last_commit_at := 0
var _frame_start := 0
var _frame_results: Array = []
var _frame_accepted: Array = []
var _finish_requested := false

func setup(runtime: Node) -> void:
	network = runtime
	planned_tick = network.tick
	committed_tick = network.tick
	clock_ready = network.is_host
	input_delay_ticks = configured_input_delay_ticks()
	delay_schedule = [{"from_tick": 0, "ticks": input_delay_ticks}]

func _ticks_for(seconds: float) -> int:
	return clampi(ceili(seconds * RATE * network.match_speed / FRAME) * FRAME, FRAME, 180)

func configured_input_delay_ticks() -> int:
	return _ticks_for(INPUT_DELAY_SECONDS)

func source_tick() -> int:
	var source := int(network.tick) + (FRAME if network._frame_step > 0 else 0)
	input_delay_ticks = delay_for_source(source)
	return source

func delay_for_source(source: int) -> int:
	var value := input_delay_ticks
	for policy in delay_schedule:
		if int(policy.from_tick) > source: break
		value = int(policy.ticks)
	return value

func _delivery_usec() -> int:
	return maxi(12000, ceili(rtt_usec * 0.5) + 10000)

func _pipeline_ticks() -> int:
	# A frame completes two physics steps after its scheduled start. Prepare
	# far enough ahead for delivery plus a poll/physics-step margin. This is
	# transport buffering, independent of the real-time input budget.
	return _ticks_for((float(_delivery_usec()) + FRAME * 1000000.0 / RATE / network.match_speed) / 1000000.0)

func _receive_policy(from_tick: int, ticks: int) -> bool:
	for policy in delay_schedule:
		if int(policy.from_tick) == from_tick: return int(policy.ticks) == ticks
	# Snapshots already contain older announcements; repeated commits may
	# legitimately refer to an entry that has since been pruned.
	if not delay_schedule.is_empty() and from_tick < int(delay_schedule[0].from_tick): return true
	if from_tick <= source_tick() or (not delay_schedule.is_empty() and from_tick < int(delay_schedule.back().from_tick)): return false
	delay_schedule.append({"from_tick": from_tick, "ticks": ticks})
	return true

func _prune_policies() -> void:
	while delay_schedule.size() > 2 and int(delay_schedule[1].from_tick) < int(network.tick) - 180:
		delay_schedule.pop_front()

func enqueue(command: Dictionary, team: int, seq: int, source: int, target: int) -> bool:
	if not network.is_host or team not in [0, 1]: return false
	if pending.size() >= MAX_PENDING or target != source + delay_for_source(source) or target > source + 180 or target % FRAME != 0 or source % FRAME != 0:
		if seq > 0 and rejected.size() < MAX_PENDING: rejected.append({"team": team, "seq": seq, "accepted": false})
		return false
	# The short input budget cannot cover every link. Never edit an already
	# published frame: defer late orders to the next open frame on both sides.
	# Preserve sequence order even across a changing delay policy.
	target = maxi(target, planned_tick + FRAME)
	if seq > 0: target = maxi(target, int(_last_manual_target[team]))
	if target > source + 180:
		if seq > 0 and rejected.size() < MAX_PENDING: rejected.append({"team": team, "seq": seq, "accepted": false})
		return false
	if seq > 0: _last_manual_target[team] = target
	var item := {"team": team, "seq": seq, "command": command.duplicate(true), "target": target}
	pending.append(item)
	return true

func reset_clock_sampling() -> void:
	# Loading/restoring a world blocks the main loop. Requests already queued
	# before that work must not turn its CPU time into a persistent RTT estimate.
	# Keep the calibrated offset and agreed timing; discard only measurements.
	_probes.clear()
	_clock_samples.clear()
	_clock_resume_usec = Time.get_ticks_usec() + 200000
	_probe_at = _clock_resume_usec

func _can_sample_clock(now: int) -> bool:
	return network.synchronized and not network._awaiting_keyframe and now >= _clock_resume_usec and (not network.is_host or network._guest_ack_tick >= 0)

func poll(now: int) -> void:
	if network.spectator or network._terminal: return
	if _can_sample_clock(now) and now >= _probe_at:
		_nonce += 1
		_probes[_nonce] = now
		for nonce in _probes.keys():
			if now - int(_probes[nonce]) > 5000000: _probes.erase(nonce)
		network.session.send_fair_message({"type": "clock_probe", "nonce": _nonce, "sent_usec": now})
		_probe_at = now + (200000 if _clock_samples.size() < 3 else 1000000)
	if not network.synchronized: return
	if network.is_host and network._guest_ack_tick >= 0 and network._pending_winner < 0:
		_prepare()
		_commit(now)

func receive(message: Dictionary) -> bool:
	var kind := str(message.get("type", ""))
	var now := Time.get_ticks_usec()
	match kind:
		"clock_probe":
			if not _can_sample_clock(now): return true
			network.session.send_fair_message({"type": "clock_reply", "nonce": int(message.nonce), "sent_usec": int(message.sent_usec), "received_usec": now})
			return true
		"clock_reply":
			if not _can_sample_clock(now): return true
			var nonce := int(message.nonce)
			if not _probes.has(nonce) or int(message.sent_usec) != int(_probes[nonce]): return true
			var elapsed := float(now - int(_probes[nonce]))
			_probes.erase(nonce)
			if elapsed < 0.0 or elapsed > 5000000.0: return true
			var offset := float(message.received_usec) - (float(message.sent_usec) + float(now)) * 0.5
			_clock_samples.append({"rtt": elapsed, "offset": offset})
			if _clock_samples.size() > 8: _clock_samples.pop_front()
			var samples: Array = _clock_samples.map(func(sample: Dictionary): return float(sample.rtt))
			samples.sort()
			rtt_usec = float(samples[mini(samples.size() - 1, floori(samples.size() * 0.75))])
			var best: Dictionary = _clock_samples[0]
			for sample in _clock_samples:
				if float(sample.rtt) < float(best.rtt): best = sample
			if not network.is_host: clock_offset_usec = float(best.offset) if not clock_ready else lerpf(clock_offset_usec, float(best.offset), 0.25)
			clock_ready = true
			_ack_plans()
			return true
		"input_frame":
			if network.is_host or not network.synchronized: return true
			var incoming := int(message.tick)
			if incoming <= network.tick: return true
			if plans.has(incoming):
				if plans[incoming] != message: network._request_keyframe()
				else: _ack_plans()
				return true
			if incoming != planned_tick + FRAME:
				network._request_keyframe()
				return true
			plans[incoming] = message.duplicate(true)
			planned_tick = incoming
			_ack_plans()
			return true
		"input_step":
			if network.is_host or not network.synchronized: return true
			var incoming := int(message.tick)
			if incoming <= network.tick: return true
			var plan := {"type": "input_frame", "tick": incoming, "commands": message.commands}
			if commits.has(incoming):
				if commits[incoming] != message or plans.get(incoming) != plan: network._request_keyframe()
				return true
			if incoming != committed_tick + FRAME or incoming != planned_tick + FRAME:
				network._request_keyframe()
				return true
			if message.has("timing"):
				var timing: Dictionary = message.timing
				if not _receive_policy(int(timing.delay_from_tick), int(timing.input_delay_ticks)):
					network._request_keyframe()
					return true
				network._apply_match_speed(float(timing.speed))
			plans[incoming] = plan.duplicate(true)
			commits[incoming] = message.duplicate(true)
			planned_tick = incoming
			committed_tick = incoming
			_ack_plans()
			return true
		"input_ack":
			if network.is_host: ready_tick = maxi(ready_tick, mini(int(message.tick), planned_tick))
			return true
		"input_commit":
			if network.is_host or not network.synchronized: return true
			var incoming := int(message.tick)
			if incoming <= network.tick: return true
			if commits.has(incoming):
				if commits[incoming] != message: network._request_keyframe()
				return true
			if incoming != committed_tick + FRAME or not plans.has(incoming):
				network._request_keyframe()
				return true
			commits[incoming] = message.duplicate(true)
			committed_tick = incoming
			if not _receive_policy(int(message.delay_from_tick), int(message.input_delay_ticks)):
				network._request_keyframe()
				return true
			network._apply_match_speed(float(message.speed))
			return true
		"frame":
			if network.is_host: return false
			if network.synchronized and int(message.tick) > network.tick - 180:
				confirmations[int(message.tick)] = message.duplicate(true)
				_confirm()
			return true
	return false

func _ack_plans() -> void:
	if _needs_plan_ack and not network.is_host and clock_ready and network.synchronized and planned_tick > network.tick:
		if network.session.send_fair_message({"type": "input_ack", "tick": planned_tick}): _needs_plan_ack = false

func _prepare() -> void:
	# Keep multiple committed frames in flight when the link needs it. Limiting
	# this to the short input delay makes every frame wait another delivery
	# interval, slowing the entire match. Late inputs already use the next open
	# frame, so publishing ahead never mutates or drops their commands.
	var horizon := _pipeline_ticks()
	while planned_tick < network.tick + horizon:
		var target := planned_tick + FRAME
		var groups := {0: [], 1: []}
		var remaining: Array = []
		for item in pending:
			if int(item.target) > target:
				remaining.append(item)
				continue
			var wire: Dictionary = item.duplicate(true)
			wire.erase("target")
			groups[int(wire.team)].append(wire)
		pending = remaining
		for group in groups.values():
			group.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seq) < int(b.seq))
		var commands: Array = []
		var first_team := int(target / FRAME) % 2
		# Alternate both the first team and individual slots under saturation.
		# Neither arrival order nor host identity can monopolize the frame.
		while commands.size() < 62 and (not groups[0].is_empty() or not groups[1].is_empty()):
			for side in [first_team, 1 - first_team]:
				if not groups[side].is_empty() and commands.size() < 62: commands.append(groups[side].pop_front())
		for group in groups.values():
			for item in group:
				if int(item.seq) > 0 and rejected.size() < MAX_PENDING: rejected.append({"team": item.team, "seq": item.seq, "accepted": false})
		var plan := {"type": "input_frame", "tick": target, "commands": commands}
		plans[target] = plan
		planned_tick = target
		if committed_tick == 0:
			_startup_plan_tick = target
			if not network.session.send_fair_message(plan): network._abort_sync("提前指令帧发送失败"); return

func _commit(now: int) -> void:
	var spacing := roundi(1000000.0 * FRAME / RATE / network.match_speed)
	var guard := _delivery_usec()
	# Only startup waits for a clock-calibrated receipt. Steady-state plans
	# and deadlines are sent in one packet immediately, without batch waiting.
	if committed_tick == 0 and ready_tick == 0: return
	while committed_tick < planned_tick:
		var target := committed_tick + FRAME
		if not plans.has(target): break
		var start := maxi(_last_commit_at + spacing, now + guard)
		var message := {"type": "input_commit", "tick": target, "execute_at_usec": start, "speed": network.match_speed, "input_delay_ticks": int(delay_schedule.back().ticks), "delay_from_tick": int(delay_schedule.back().from_tick)}
		var timing := {"speed": network.match_speed, "input_delay_ticks": int(delay_schedule.back().ticks), "delay_from_tick": int(delay_schedule.back().from_tick)}
		if target > _startup_plan_tick:
			message = {"type": "input_step", "tick": target, "execute_at_usec": start, "commands": plans[target].commands}
			if timing != _last_sent_timing: message["timing"] = timing.duplicate(true)
		_last_sent_timing = timing
		commits[target] = message
		committed_tick = target
		_last_commit_at = start
		if not network.session.send_fair_message(message): network._abort_sync("指令帧确认发送失败"); return

func advance(now: int, budget: int) -> int:
	if not clock_ready or not network.synchronized or network._awaiting_keyframe: return 0
	if network._pending_winner >= 0 and network._frame_step == 0: return 0
	var host_now := now + roundi(clock_offset_usec)
	var steps := 0
	while steps < mini(budget, 4):
		var target: int = network.tick + FRAME
		if not commits.has(target) or not plans.has(target): break
		var start := int(commits[target].execute_at_usec)
		var due := start + roundi(float(network._frame_step) * 1000000.0 / RATE / network.match_speed)
		if host_now < due: break
		if network._frame_step == 0:
			if network.is_host and (network._pending_winner >= 0 or network.tick - network._guest_ack_tick >= _ticks_for(0.6)): break
			_frame_start = start
			_begin(plans[target])
		network._step_frame()
		steps += 1
		if network._frame_step >= FRAME:
			_finish(target)
			if network._terminal or network._pending_winner >= 0: break
	return steps

func _begin(plan: Dictionary) -> void:
	network._frame_running = network.is_host
	network._replaying = not network.is_host
	_frame_accepted = []
	_frame_results = []
	for item in plan.commands:
		var command: Dictionary = item.command
		var accepted := false
		if int(item.seq) == 0 and command.get("op") == "match_end" and int(item.team) == int(network.session.host_team):
			network.match_state.set_winner(int(command.winner) as Enums.Team)
			accepted = true
		else:
			accepted = network.execute_team_command(command, int(item.team), int(item.seq))
		if accepted:
			_frame_accepted.append({"team": item.team, "command": command})
			network._index_host_entities()
		if int(item.seq) > 0: _frame_results.append({"team": item.team, "seq": item.seq, "accepted": accepted})
	network._frame_running = false
	network._replaying = false

func _finish(target: int) -> void:
	network.tick = target
	input_delay_ticks = delay_for_source(target)
	_prune_policies()
	network._frame_step = 0
	network.last_checksum = str(network.simulation.frame_checksum())
	if network.is_host:
		network._checksums[target] = network.last_checksum
		var results := _frame_results + rejected.slice(0, 256 - _frame_results.size())
		rejected = rejected.slice(256 - _frame_results.size())
		# Late spectators restore speed from their keyframe. Repeat it only
		# when changed, not periodically in otherwise empty completed frames.
		if network.match_speed != _last_frame_speed:
			_last_frame_speed = network.match_speed
			_frame_accepted.append({"team": network.local_team, "command": {"op": "match_speed", "speed": network.match_speed}})
		if not network.session.send_frame(target, _frame_accepted, network.last_checksum, results): network._abort_sync("执行确认发送失败"); return
		_resolve(results, target)
		for request in network._keyframe_requests: network._send_keyframe(request)
		network._keyframe_requests.clear()
		if network._pending_winner >= 0: network.session.finish_match(network._pending_winner)
	else:
		completed[target] = {"checksum": network.last_checksum, "results": _frame_results.duplicate(true)}
		_confirm()
	plans.erase(target)
	commits.erase(target)

func _confirm() -> void:
	for target in completed.keys():
		if not confirmations.has(target): break
		var frame: Dictionary = confirmations[target]
		var actual: Dictionary = completed[target]
		var outcomes_match := true
		for result in actual.results:
			if result not in frame.results: outcomes_match = false
		if actual.checksum != frame.checksum or not outcomes_match:
			network.desync_count += 1
			network._request_keyframe()
			return
		_resolve(frame.results, int(target))
		network.frames_received += 1
		network._resync_attempts = 0
		network._last_snapshot_received_usec = Time.get_ticks_usec()
		network.session.send_ack(int(target), str(actual.checksum))
		completed.erase(target)
		confirmations.erase(target)

func _resolve(results: Array, at_tick: int) -> void:
	for result in results:
		if int(result.team) == network.local_team:
			network.resolve_local_input(int(result.seq), bool(result.accepted), at_tick)

func reset(at_tick: int) -> void:
	reset_clock_sampling()
	_needs_plan_ack = true
	plans.clear()
	commits.clear()
	completed.clear()
	confirmations.clear()
	planned_tick = at_tick
	committed_tick = at_tick

func resend() -> void:
	# The relay allows immutable resends of uncompleted prepared frames.
	for target in plans:
		if int(target) <= network.tick: continue
		if commits.has(target) and commits[target].type == "input_step":
			network.session.send_fair_message(commits[target])
		else:
			network.session.send_fair_message(plans[target])
			if commits.has(target): network.session.send_fair_message(commits[target])

func drain() -> void:
	# Match-ended follows the final completed frame. Drain only confirmed ticks,
	# never future plans that were prepared beyond the winning frame.
	while confirmations.has(int(network.tick) + FRAME):
		var target: int = network.tick + FRAME
		if not plans.has(target): break
		if network._frame_step == 0: _begin(plans[target])
		while network._frame_step < FRAME: network._step_frame()
		_finish(target)

func request_finish(winner: int) -> void:
	if not network.is_host or winner not in [0, 1] or _finish_requested: return
	_finish_requested = true
	for item in pending:
		if item.command.get("op") == "match_end": return
	var source := source_tick()
	enqueue({"op": "match_end", "winner": winner}, network.local_team, 0, source, source + delay_for_source(source))
