extends RefCounted

## Event-driven silent lockstep (Protocol v10).
## Empty frames send zero network packets; both peers advance on an aligned
## monotonic clock and exchange compact binary schedules only when commands or
## timing changes occur, plus a 1 Hz binary heartbeat with 32-bit digest.
const WireCodec := preload("res://scripts/network/wire_codec.gd")
const FRAME := 3
const RATE := 30.0
const MAX_PENDING := 256
const INPUT_DELAY_SECONDS := 0.1 # Real seconds, independent of match speed.

var network: Node
var pending: Array = []
var rejected: Array = []
var confirmed_schedules: Dictionary = {}
var in_flight: Dictionary = {}
var last_scheduled_tick := 0
var epoch_tick := 0
var epoch_usec := 0
var timeline_ready := false
var _next_schedule_id := 0
var _last_accepted_schedule_id := 0
var _reschedule_barrier_tick := -1
var _needs_sync_ack := true
var _last_sent_timing: Dictionary = {}
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
var _checksums32: Dictionary = {}
var _hb_sent_usec: Dictionary = {}
var _last_heartbeat_tick := 0
var _expected_heartbeats: Dictionary = {}
var _last_host_tick := 0
var _frame_results: Array = []
var _finish_requested := false


func setup(runtime: Node) -> void:
	network = runtime
	last_scheduled_tick = network.tick
	epoch_tick = network.tick
	clock_ready = network.is_host
	input_delay_ticks = configured_input_delay_ticks()
	delay_schedule = [{"from_tick": 0, "ticks": input_delay_ticks}]


func is_ready() -> bool:
	return timeline_ready and clock_ready


static func checksum32(hex_checksum: String) -> int:
	return WireCodec.checksum32(hex_checksum)


func record_checksum(at_tick: int, hex_checksum: String) -> void:
	_checksums32[at_tick] = checksum32(hex_checksum)
	for old in _checksums32.keys():
		if int(old) < int(network.tick) - 360:
			_checksums32.erase(old)


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


func _schedule_lead_usec() -> int:
	return maxi(20000, ceili(rtt_usec * 1.05) + 15000)


func _heartbeat_interval_ticks() -> int:
	return maxi(30, roundi(RATE * network.match_speed / 30.0) * 30)


func _min_open_tick() -> int:
	return maxi(int(network.tick) + (FRAME if network._frame_step > 0 else 0) + FRAME, last_scheduled_tick + FRAME)


func _current_timing() -> Dictionary:
	return {
		"speed": network.match_speed,
		"input_delay_ticks": int(delay_schedule.back().ticks),
		"delay_from_tick": int(delay_schedule.back().from_tick),
	}


func _anchor_for_future_tick() -> Array:
	var anchor_tick := epoch_tick
	var anchor_usec := epoch_usec
	var anchor_speed: float = network.match_speed
	var keys := confirmed_schedules.keys()
	keys.sort()
	for t in keys:
		if int(t) <= int(network.tick): continue
		var sched: Dictionary = confirmed_schedules[t]
		anchor_tick = int(t) - FRAME
		anchor_usec = int(sched.epoch_usec)
		if sched.has("timing"):
			anchor_speed = float(sched.timing.speed)
	return [anchor_tick, anchor_usec, anchor_speed]


func frame_start_usec(target_tick: int) -> int:
	var offset_ticks := target_tick - FRAME - epoch_tick
	return epoch_usec + roundi(float(offset_ticks) * 1000000.0 / (RATE * network.match_speed))


func step_due_usec(target_tick: int, step: int) -> int:
	var offset_ticks := target_tick - FRAME - epoch_tick
	return epoch_usec + roundi(float(offset_ticks + step) * 1000000.0 / (RATE * network.match_speed))


func _receive_policy(from_tick: int, ticks: int) -> bool:
	for policy in delay_schedule:
		if int(policy.from_tick) == from_tick: return int(policy.ticks) == ticks
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
		if seq > 0 and rejected.size() < MAX_PENDING: rejected.append({"team": team, "seq": seq})
		return false
	target = maxi(target, _min_open_tick())
	if seq > 0: target = maxi(target, int(_last_manual_target[team]))
	if target > source + 180:
		if seq > 0 and rejected.size() < MAX_PENDING: rejected.append({"team": team, "seq": seq})
		return false
	if seq > 0: _last_manual_target[team] = target
	var canonical := WireCodec.canonical_command(command)
	pending.append({"team": team, "seq": seq, "command": canonical, "target": target})
	return true


func reset_clock_sampling() -> void:
	_probes.clear()
	_clock_samples.clear()
	_clock_resume_usec = Time.get_ticks_usec() + 200000
	_probe_at = _clock_resume_usec


func _can_sample_clock(now: int) -> bool:
	return network._playing and network.synchronized and not network._awaiting_keyframe and now >= _clock_resume_usec


func _record_rtt_sample(elapsed: float, offset := 0.0, update_offset := false) -> void:
	if elapsed < 0.0 or elapsed > 5000000.0: return
	_clock_samples.append({"rtt": elapsed, "offset": offset})
	if _clock_samples.size() > 8: _clock_samples.pop_front()
	var samples: Array = _clock_samples.map(func(sample: Dictionary): return float(sample.rtt))
	samples.sort()
	rtt_usec = float(samples[mini(samples.size() - 1, floori(samples.size() * 0.75))])
	if update_offset:
		var best: Dictionary = _clock_samples[0]
		for sample in _clock_samples:
			if float(sample.rtt) < float(best.rtt): best = sample
		clock_offset_usec = float(best.offset) if not clock_ready else lerpf(clock_offset_usec, float(best.offset), 0.25)
		clock_ready = true


func poll(now: int) -> void:
	if network.spectator or network._terminal: return
	if _can_sample_clock(now) and now >= _probe_at:
		var should_probe: bool = (not network.is_host) or _clock_samples.is_empty()
		if should_probe:
			_nonce += 1
			_probes[_nonce] = now
			for nonce in _probes.keys():
				if now - int(_probes[nonce]) > 5000000: _probes.erase(nonce)
			network.session.send_fair_message({"type": "clock_probe", "nonce": _nonce, "sent_usec": now})
			if network.is_host:
				_probe_at = now + 200000
			else:
				_probe_at = now + (100000 if _clock_samples.size() < 3 else 10000000)
	if not network.synchronized: return
	if not network.is_host:
		_maybe_send_sync_ack()
		return
	if timeline_ready and network._pending_winner < 0:
		_schedule(now)


func _maybe_send_sync_ack() -> void:
	if _needs_sync_ack and not network.is_host and clock_ready and network.synchronized and not network._awaiting_keyframe:
		var csum := int(_checksums32.get(network.tick, checksum32(network.last_checksum)))
		if network.session.send_heartbeat_ack(network.tick, csum, 0):
			_needs_sync_ack = false


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
			_record_rtt_sample(elapsed, offset, not network.is_host)
			_maybe_send_sync_ack()
			return true
		"sync_init":
			if network.is_host or not network.synchronized or network._awaiting_keyframe: return true
			var sync_tick := int(message.tick)
			var csum := int(message.checksum32)
			if sync_tick != network.tick or not _checksums32.has(sync_tick) or int(_checksums32[sync_tick]) != csum:
				network._request_keyframe()
				return true
			if sync_tick == 0:
				delay_schedule = [{"from_tick": int(message.delay_from_tick), "ticks": int(message.input_delay_ticks)}]
			elif not _receive_policy(int(message.delay_from_tick), int(message.input_delay_ticks)):
				network._request_keyframe()
				return true
			input_delay_ticks = delay_for_source(source_tick())
			network._apply_match_speed(float(message.speed))
			epoch_tick = sync_tick
			epoch_usec = int(message.epoch_usec)
			timeline_ready = true
			_last_host_tick = sync_tick
			_reschedule_barrier_tick = -1
			network._last_snapshot_received_usec = now
			network._set_status("联机对战 · 玩家 · 静默同步")
			return true
		"schedule":
			if network.is_host or not network.synchronized or network._awaiting_keyframe: return true
			var sched_id := int(message.id)
			var target := int(message.tick)
			var guest_frontier := int(network.tick) + (FRAME if network._frame_step > 0 else 0)
			if sched_id == _last_accepted_schedule_id:
				network.session.send_fair_message({"type": "schedule_ack", "id": sched_id, "accepted": true, "guest_tick": guest_frontier})
				return true
			if sched_id < _last_accepted_schedule_id:
				return true
			if guest_frontier < target and (_reschedule_barrier_tick < 0 or target > _reschedule_barrier_tick):
				if message.has("timing"):
					var timing: Dictionary = message.timing
					if not _receive_policy(int(timing.delay_from_tick), int(timing.input_delay_ticks)):
						network._request_keyframe()
						return true
				_last_accepted_schedule_id = sched_id
				confirmed_schedules[target] = message.duplicate(true)
				_last_host_tick = maxi(_last_host_tick, target)
				_reschedule_barrier_tick = -1
				network.session.send_fair_message({"type": "schedule_ack", "id": sched_id, "accepted": true, "guest_tick": guest_frontier})
			else:
				_reschedule_barrier_tick = maxi(_reschedule_barrier_tick, guest_frontier)
				network.session.send_fair_message({"type": "schedule_ack", "id": sched_id, "accepted": false, "guest_tick": _reschedule_barrier_tick})
			return true
		"schedule_ack":
			if not network.is_host or not network.synchronized: return true
			if in_flight.is_empty() or int(message.id) != int(in_flight.id): return true
			var acked_sched := in_flight
			in_flight = {}
			if bool(message.accepted):
				confirmed_schedules[int(acked_sched.tick)] = acked_sched
				_schedule(now)
			else:
				_reschedule_rejected(acked_sched, int(message.guest_tick), now)
			return true
		"heartbeat":
			if network.is_host or not network.synchronized or network._awaiting_keyframe: return true
			var hb_tick := int(message.tick)
			var csum := int(message.checksum32)
			var sent32 := int(message.sent_usec32)
			_last_host_tick = maxi(_last_host_tick, hb_tick)
			if hb_tick <= network.tick:
				if _checksums32.has(hb_tick) and int(_checksums32[hb_tick]) != csum:
					network.desync_count += 1
					network._request_keyframe()
					return true
				network.frames_received += 1
				network._resync_attempts = 0
				network._last_snapshot_received_usec = now
				network.session.send_heartbeat_ack(hb_tick, int(_checksums32.get(hb_tick, csum)), sent32)
			else:
				_expected_heartbeats[hb_tick] = {"checksum32": csum, "sent_usec32": sent32}
			return true
		"heartbeat_ack":
			if not network.is_host or not network.synchronized: return true
			var ack_tick := int(message.ack_tick)
			var csum := int(message.checksum32)
			var echo32 := int(message.echo_usec32)
			if not timeline_ready:
				if ack_tick == network.tick and _checksums32.has(ack_tick) and int(_checksums32[ack_tick]) == csum:
					network._guest_ack_tick = ack_tick
					network._last_snapshot_received_usec = now
					epoch_tick = ack_tick
					epoch_usec = now + _delivery_usec()
					timeline_ready = true
					_last_sent_timing = _current_timing()
					last_scheduled_tick = ack_tick
					_last_heartbeat_tick = ack_tick
					var sync_msg := {
						"type": "sync_init",
						"tick": ack_tick,
						"epoch_usec": epoch_usec,
						"speed": network.match_speed,
						"input_delay_ticks": int(delay_schedule.back().ticks),
						"delay_from_tick": int(delay_schedule.back().from_tick),
						"checksum32": csum,
					}
					if not network.session.send_fair_message(sync_msg):
						network._abort_sync("开局同步发送失败")
						return true
					network._set_status("联机对战 · 主机 · 静默同步")
					_schedule(now)
				else:
					var mismatch_sync := {
						"type": "sync_init",
						"tick": network.tick,
						"epoch_usec": now + _delivery_usec(),
						"speed": network.match_speed,
						"input_delay_ticks": int(delay_schedule.back().ticks),
						"delay_from_tick": int(delay_schedule.back().from_tick),
						"checksum32": int(_checksums32.get(network.tick, 0)),
					}
					network.session.send_fair_message(mismatch_sync)
				return true
			if _checksums32.has(ack_tick) and int(_checksums32[ack_tick]) == csum:
				network._guest_ack_tick = maxi(network._guest_ack_tick, ack_tick)
				network._last_snapshot_received_usec = now
				network._set_status("联机对战 · 主机 · 静默同步")
				if echo32 != 0 and _hb_sent_usec.has(ack_tick):
					_record_rtt_sample(float(now - int(_hb_sent_usec[ack_tick])))
					_hb_sent_usec.erase(ack_tick)
			return true
	return false


func _reschedule_rejected(acked_sched: Dictionary, guest_tick: int, now: int) -> void:
	if guest_tick < network.tick or guest_tick - network.tick > 360:
		network._abort_sync("日程同步超出可恢复范围")
		return
	var restored: Array = []
	for entry in acked_sched.commands:
		restored.append({"team": entry.team, "seq": entry.seq, "command": entry.command.duplicate(true), "target": guest_tick + FRAME})
	pending = restored + pending
	if acked_sched.has("rejected"):
		rejected = acked_sched.rejected.duplicate(true) + rejected
	if acked_sched.has("timing"):
		_last_sent_timing = {}
	while network.tick < guest_tick:
		if network._frame_step == 0:
			var next_tick := int(network.tick) + FRAME
			if confirmed_schedules.has(next_tick):
				_apply_schedule_frame(confirmed_schedules[next_tick])
			else:
				_frame_results = []
		while network._frame_step < FRAME:
			network._step_frame()
		_finish(int(network.tick) + FRAME)
	last_scheduled_tick = guest_tick
	epoch_tick = guest_tick
	epoch_usec = now + _schedule_lead_usec()
	_schedule(now)


func _schedule(now: int) -> void:
	if not network.is_host or not timeline_ready or not in_flight.is_empty(): return
	var timing := _current_timing()
	var timing_changed := timing != _last_sent_timing
	if pending.is_empty() and rejected.is_empty() and not timing_changed: return

	var min_open := _min_open_tick()
	var anchor := _anchor_for_future_tick()
	var anchor_tick := int(anchor[0])
	var anchor_usec := int(anchor[1])
	var anchor_speed := float(anchor[2])
	var lead := _schedule_lead_usec()
	var min_lead_tick := min_open
	while anchor_usec + roundi(float(min_lead_tick - FRAME - anchor_tick) * 1000000.0 / (RATE * anchor_speed)) < now + lead:
		min_lead_tick += FRAME

	var target := min_lead_tick
	if not pending.is_empty():
		var earliest := int(pending[0].target)
		for item in pending:
			earliest = mini(earliest, int(item.target))
		target = maxi(min_lead_tick, earliest)

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
	while commands.size() < 62 and (not groups[0].is_empty() or not groups[1].is_empty()):
		for side in [first_team, 1 - first_team]:
			if not groups[side].is_empty() and commands.size() < 62:
				commands.append(groups[side].pop_front())
	for group in groups.values():
		for item in group:
			if int(item.seq) > 0 and rejected.size() < MAX_PENDING:
				rejected.append({"team": item.team, "seq": item.seq})

	var sched_rejected: Array = rejected.slice(0, 255)
	rejected = rejected.slice(sched_rejected.size())
	if commands.is_empty() and sched_rejected.is_empty() and not timing_changed:
		return

	var base_start := anchor_usec + roundi(float(target - FRAME - anchor_tick) * 1000000.0 / (RATE * anchor_speed))
	var sched_epoch_usec := maxi(base_start, now + lead)
	_next_schedule_id += 1
	var message := {"type": "schedule", "id": _next_schedule_id, "tick": target, "epoch_usec": sched_epoch_usec, "commands": commands}
	if timing_changed:
		message["timing"] = timing.duplicate(true)
	if not sched_rejected.is_empty():
		message["rejected"] = sched_rejected
	_last_sent_timing = timing.duplicate(true)
	in_flight = message.duplicate(true)
	last_scheduled_tick = target
	if not network.session.send_fair_message(message):
		network._abort_sync("指令日程发送失败")


func _apply_schedule_frame(sched: Dictionary) -> void:
	var target := int(sched.tick)
	epoch_tick = target - FRAME
	epoch_usec = int(sched.epoch_usec)
	if sched.has("timing"):
		network._apply_match_speed(float(sched.timing.speed))
	_begin(sched)


func advance(now: int, budget: int) -> int:
	if not is_ready() or not network.synchronized or network._awaiting_keyframe: return 0
	if network._pending_winner >= 0 and network._frame_step == 0: return 0
	var host_now := now + roundi(clock_offset_usec)
	var steps := 0
	while steps < mini(budget, 4):
		var target: int = network.tick + FRAME
		if network._frame_step == 0:
			if network._pending_winner >= 0: break
			if network.is_host:
				if network.tick - network._guest_ack_tick >= _ticks_for(3.0): break
				if not in_flight.is_empty() and target >= int(in_flight.tick): break
			else:
				if _reschedule_barrier_tick >= 0 and network.tick >= _reschedule_barrier_tick: break
				if network.tick - _last_host_tick >= _ticks_for(3.0): break
			var due := int(confirmed_schedules[target].epoch_usec) if confirmed_schedules.has(target) else step_due_usec(target, 0)
			if host_now < due: break
			if confirmed_schedules.has(target):
				_apply_schedule_frame(confirmed_schedules[target])
			else:
				_frame_results = []
		else:
			var due := step_due_usec(target, network._frame_step)
			if host_now < due: break
		network._step_frame()
		steps += 1
		if network._frame_step >= FRAME:
			_finish(target)
			if network._terminal or network._pending_winner >= 0: break
	return steps


func _begin(plan: Dictionary) -> void:
	network._frame_running = network.is_host
	network._replaying = not network.is_host
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
			network._index_host_entities()
		if int(item.seq) > 0:
			_frame_results.append({"team": item.team, "seq": item.seq, "accepted": accepted})
	if plan.has("rejected"):
		for rej in plan.rejected:
			_frame_results.append({"team": rej.team, "seq": rej.seq, "accepted": false})
	network._frame_running = false
	network._replaying = false


func _finish(target: int) -> void:
	network.tick = target
	input_delay_ticks = delay_for_source(target)
	_prune_policies()
	network._frame_step = 0
	network.last_checksum = str(network.simulation.frame_checksum())
	record_checksum(target, network.last_checksum)
	confirmed_schedules.erase(target)
	_resolve(_frame_results, target)
	_frame_results = []
	if network.is_host:
		network._checksums[target] = network.last_checksum
		for old in network._checksums.keys():
			if int(old) < target - 360:
				network._checksums.erase(old)
		if target % 30 == 0 and target - _last_heartbeat_tick >= _heartbeat_interval_ticks():
			var now := Time.get_ticks_usec()
			var usec32 := now & 0xFFFFFFFF
			if usec32 == 0: usec32 = 1
			_hb_sent_usec[target] = now
			for old in _hb_sent_usec.keys():
				if int(old) < target - 360: _hb_sent_usec.erase(old)
			_last_heartbeat_tick = target
			if not network.session.send_fair_message({"type": "heartbeat", "tick": target, "checksum32": int(_checksums32[target]), "sent_usec32": usec32}):
				network._abort_sync("心跳同步发送失败")
				return
		for request in network._keyframe_requests: network._send_keyframe(request)
		network._keyframe_requests.clear()
		if network._pending_winner >= 0: network.session.finish_match(network._pending_winner, target)
	else:
		if _expected_heartbeats.has(target):
			var hb: Dictionary = _expected_heartbeats[target]
			_expected_heartbeats.erase(target)
			if int(hb.checksum32) != int(_checksums32[target]):
				network.desync_count += 1
				network._request_keyframe()
				return
			network.frames_received += 1
			network._resync_attempts = 0
			network._last_snapshot_received_usec = Time.get_ticks_usec()
			network.session.send_heartbeat_ack(target, int(_checksums32[target]), int(hb.sent_usec32))


func _resolve(results: Array, at_tick: int) -> void:
	for result in results:
		if int(result.team) == network.local_team:
			network.resolve_local_input(int(result.seq), bool(result.accepted), at_tick)


func reset(at_tick: int) -> void:
	reset_clock_sampling()
	_needs_sync_ack = true
	timeline_ready = false
	confirmed_schedules.clear()
	in_flight.clear()
	_expected_heartbeats.clear()
	_hb_sent_usec.clear()
	_reschedule_barrier_tick = -1
	_last_host_tick = at_tick
	_last_heartbeat_tick = at_tick
	last_scheduled_tick = at_tick
	epoch_tick = at_tick
	_checksums32.clear()


func on_send_keyframe() -> void:
	var at_tick := int(network.tick)
	var recovered: Array = []
	var keys := confirmed_schedules.keys()
	keys.sort()
	for t in keys:
		if int(t) > at_tick:
			for entry in confirmed_schedules[t].commands:
				recovered.append({"team": entry.team, "seq": entry.seq, "command": entry.command.duplicate(true), "target": maxi(int(t), at_tick + FRAME)})
			if confirmed_schedules[t].has("rejected"):
				rejected = confirmed_schedules[t].rejected.duplicate(true) + rejected
	if not in_flight.is_empty() and int(in_flight.tick) > at_tick:
		for entry in in_flight.commands:
			recovered.append({"team": entry.team, "seq": entry.seq, "command": entry.command.duplicate(true), "target": maxi(int(in_flight.tick), at_tick + FRAME)})
		if in_flight.has("rejected"):
			rejected = in_flight.rejected.duplicate(true) + rejected
	pending = recovered + pending
	confirmed_schedules.clear()
	in_flight.clear()
	timeline_ready = false
	network._guest_ack_tick = -1
	last_scheduled_tick = at_tick
	_last_heartbeat_tick = at_tick
	_hb_sent_usec.clear()
	record_checksum(at_tick, network.last_checksum)
	reset_clock_sampling()


func drain(final_tick := -1) -> void:
	var goal := final_tick
	if goal < 0 and not confirmed_schedules.is_empty():
		var keys := confirmed_schedules.keys()
		keys.sort()
		goal = int(keys.back())
	if goal <= int(network.tick) or goal - int(network.tick) > 180: return
	while int(network.tick) < goal:
		var target := int(network.tick) + FRAME
		if network._frame_step == 0:
			if confirmed_schedules.has(target):
				_apply_schedule_frame(confirmed_schedules[target])
			else:
				_frame_results = []
		while network._frame_step < FRAME:
			network._step_frame()
		_finish(target)


func request_finish(winner: int) -> void:
	if not network.is_host or winner not in [0, 1] or _finish_requested: return
	_finish_requested = true
	for item in pending:
		if item.command.get("op") == "match_end": return
	var source := source_tick()
	enqueue({"op": "match_end", "winner": winner}, network.local_team, 0, source, source + delay_for_source(source))
