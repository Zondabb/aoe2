class_name PromptAssembler
extends RefCounted

const AiToolCatalogScript := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")

const SYSTEM_PROMPT := (
	"你是《帝国时代 II》风格即时战略对局的 AI 指挥官。"
	+ "只能通过函数工具（tool_calls）下达命令，不要输出长篇文字或内心推理。"
	+ "坐标与 entity id 必须来自下方观测，禁止编造 id。"
	+ "每 tick 返回 0 到多条 tool_calls。"
	+ "人口或资源不足时不要训练或放置建筑。"
	+ "优先让村民采集可见资源；有资源 id 时使用 gather，不要只推理不行动。"
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
		"对局 tick=%d 时间=%.1fs 文明=%s 阶段=经济"
		% [
			int(metadata.get("tick", 0)),
			float(metadata.get("time_sec", 0.0)),
			String(metadata.get("team_label", metadata.get("profile_id", ""))),
		]
	)
	lines.append(
		"经济：食物=%d 木材=%d 黄金=%d 人口=%d/%d"
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
		"己方城镇中心 id=%d 坐标=%s；敌方城镇中心 id=%d 坐标=%s"
		% [
			int(derived.get("own_tc_id", -1)),
			_fmt_pos(own_pos),
			int(derived.get("enemy_tc_id", -1)),
			_fmt_pos(enemy_pos),
		]
	)
	lines.append(
		"村民数=%d  军事单位数=%d"
		% [int(derived.get("villager_count", 0)), int(derived.get("military_count", 0))]
	)
	var entities: Array = observation.get("entities", [])
	var unit_bits: PackedStringArray = PackedStringArray()
	var resource_bits: PackedStringArray = PackedStringArray()
	for ent in entities:
		if not (ent is Dictionary):
			continue
		var kind := String((ent as Dictionary).get("kind", ""))
		if kind == "unit":
			unit_bits.append(
				"id=%d %s 指令=%s 坐标=%s"
				% [
					int(ent.get("id", -1)),
					String(ent.get("def_id", "")),
					String(ent.get("order", "NONE")),
					_fmt_pos(ent.get("pos", [])),
				]
			)
		elif kind == "resource":
			resource_bits.append(
				"id=%d 类型=%s 储量=%.0f 坐标=%s"
				% [
					int(ent.get("id", -1)),
					_resource_type_zh(String(ent.get("resource_type", "UNKNOWN"))),
					float(ent.get("amount", 0.0)),
					_fmt_pos(ent.get("pos", [])),
				]
			)
	if not unit_bits.is_empty():
		lines.append("单位：" + ", ".join(unit_bits))
	if not resource_bits.is_empty():
		lines.append("可见资源：" + ", ".join(resource_bits))
	if events.is_empty():
		lines.append("自上一 tick 事件：（无）")
	else:
		var ev_bits: PackedStringArray = PackedStringArray()
		for ev in events:
			if ev is Dictionary:
				var eid := int((ev as Dictionary).get("entity_id", -1))
				ev_bits.append("%s#%d" % [String(ev.get("type", "event")), eid])
		lines.append("自上一 tick 事件：" + ", ".join(ev_bits))
	return "\n".join(lines)


static func _resource_type_zh(name: String) -> String:
	match name:
		"FOOD":
			return "食物"
		"WOOD":
			return "木材"
		"GOLD":
			return "黄金"
		_:
			return name


static func _fmt_pos(value: Variant) -> String:
	if value is Array and (value as Array).size() >= 2:
		var arr := value as Array
		return "(%.1f,%.1f)" % [float(arr[0]), float(arr[1])]
	if value is Vector2:
		var v := value as Vector2
		return "(%.1f,%.1f)" % [v.x, v.y]
	return "(?,?)"
