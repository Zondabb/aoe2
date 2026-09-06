class_name PromptAssembler
extends RefCounted

const AiToolCatalogScript := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")

const SYSTEM_PROMPT := (
	"You are an RTS commander for an Age of Empires II style match. "
	+ "Act only through function tools. Coordinates and entity ids must come from the observation; "
	+ "do not invent ids. Return 0..N tool_calls per tick. Do not write long prose. "
	+ "Do not train or place buildings when population or resources are insufficient."
)


static func assemble(
	observation: Dictionary,
	events: Array,
	meta: Dictionary = {},
	history: Array = []
) -> Dictionary:
	var metadata := {
		"protocol_version": 2,
		"match_id": String(meta.get("match_id", "")),
		"team": int(meta.get("team", 0)),
		"tick": int(meta.get("tick", 0)),
		"time_sec": float(meta.get("time_sec", 0.0)),
		"profile_id": String(meta.get("profile_id", "")),
		"enemy_team": int(meta.get("enemy_team", 0)),
		"team_label": String(meta.get("team_label", "")),
		"backend": String(meta.get("backend", "rules_compat")),
		"log_observation": bool(meta.get("log_observation", false)),
		"llm_base_url": String(meta.get("llm_base_url", "")),
	}
	var messages: Array = [{"role": "system", "content": SYSTEM_PROMPT}]
	for item in history:
		if item is Dictionary and String((item as Dictionary).get("role", "")) != "":
			messages.append(item)
	messages.append({"role": "user", "content": render_user(observation, events, metadata)})
	return {
		"model": String(meta.get("model", "aoe2-rules-v1")),
		"stream": false,
		"temperature": 0,
		"max_tokens": int(meta.get("max_tokens", 2048)),
		"messages": messages,
		"tools": AiToolCatalogScript.tools_payload(),
		"tool_choice": "auto",
		"metadata": metadata,
		"observation": observation,
		"events": events,
	}


static func render_user(observation: Dictionary, events: Array, metadata: Dictionary) -> String:
	var econ: Dictionary = observation.get("economy", {}) as Dictionary
	var derived: Dictionary = observation.get("derived", {}) as Dictionary
	var lines: PackedStringArray = PackedStringArray()
	lines.append(
		"Match tick=%d time=%.1fs team=%s phase_hint=ECO"
		% [
			int(metadata.get("tick", 0)),
			float(metadata.get("time_sec", 0.0)),
			String(metadata.get("team_label", metadata.get("profile_id", ""))),
		]
	)
	lines.append(
		"Economy: food=%d wood=%d gold=%d pop=%d/%d"
		% [
			int(econ.get("food", 0)),
			int(econ.get("wood", 0)),
			int(econ.get("gold", 0)),
			int(econ.get("pop_used", 0)),
			int(econ.get("pop_cap", 0)),
		]
	)
	var own_pos: Variant = derived.get("own_tc_pos", [0, 0])
	var enemy_pos: Variant = derived.get("enemy_tc_pos", [0, 0])
	lines.append(
		"Base TC id=%d at %s; Enemy TC id=%d at %s"
		% [
			int(derived.get("own_tc_id", -1)),
			_fmt_pos(own_pos),
			int(derived.get("enemy_tc_id", -1)),
			_fmt_pos(enemy_pos),
		]
	)
	lines.append("Villagers: %d  Military: %d" % [
		int(derived.get("villager_count", 0)),
		int(derived.get("military_count", 0)),
	])
	var entities: Array = observation.get("entities", [])
	var unit_bits: PackedStringArray = PackedStringArray()
	var resource_bits: PackedStringArray = PackedStringArray()
	for ent in entities:
		if not (ent is Dictionary):
			continue
		var kind := String((ent as Dictionary).get("kind", ""))
		if kind == "unit":
			unit_bits.append(
				"id=%d %s order=%s pos=%s"
				% [
					int(ent.get("id", -1)),
					String(ent.get("def_id", "")),
					String(ent.get("order", "NONE")),
					_fmt_pos(ent.get("pos", [])),
				]
			)
		elif kind == "resource":
			resource_bits.append(
				"id=%d %s amount=%.0f at %s"
				% [
					int(ent.get("id", -1)),
					String(ent.get("resource_type", "UNKNOWN")),
					float(ent.get("amount", 0.0)),
					_fmt_pos(ent.get("pos", [])),
				]
			)
	if not unit_bits.is_empty():
		lines.append("Units: " + ", ".join(unit_bits))
	if not resource_bits.is_empty():
		lines.append("Visible resources: " + ", ".join(resource_bits))
	if events.is_empty():
		lines.append("Events since last tick: (none)")
	else:
		var ev_bits: PackedStringArray = PackedStringArray()
		for ev in events:
			if ev is Dictionary:
				var eid := int((ev as Dictionary).get("entity_id", -1))
				ev_bits.append("%s#%d" % [String(ev.get("type", "event")), eid])
		lines.append("Events since last tick: " + ", ".join(ev_bits))
	return "\n".join(lines)


static func _fmt_pos(value: Variant) -> String:
	if value is Array and (value as Array).size() >= 2:
		var arr := value as Array
		return "(%.1f,%.1f)" % [float(arr[0]), float(arr[1])]
	if value is Vector2:
		var v := value as Vector2
		return "(%.1f,%.1f)" % [v.x, v.y]
	return "(?,?)"
