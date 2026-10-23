class_name PromptAssembler
extends RefCounted

const AiToolCatalogScript := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")
const SERVICE_MODEL := "aoe2-service"

const SYSTEM_PROMPT := (
	"你是《帝国时代 II》风格即时战略对局的 AI 指挥官。"
	+ "只能通过函数工具（tool_calls）下达命令，不要输出长篇文字或内心推理。"
	+ "entity id 必须来自当前观测，禁止编造 id；team 标注决定敌我，只能指挥己方。"
	+ "坐标是仿真 [x,y]，可使用 construction_options、scouting.frontiers、army.rally_point 或 map_bounds 内的探索目标。"
	+ "每 tick 返回 0 到多条 tool_calls。"
	+ "人口或资源不足时不要训练或放置建筑。"
	+ "根据实际视野、兵力和资源自主选择探索、经济、扩军、集结、进攻或防守。"
	+ "缺资源点或未知敌方基地时派侦察兵探索；保持已有 MOVE 目标直到到达或卡住，不反复改路。"
	+ "让村民采集可见资源、完成已有地基；按 catalog 的真实成本和前置建兵营，再从完工建筑持续训练。"
	+ "军队先在 rally_point 屯兵，达到合适规模后协同出击；只 attack 当前可见敌人，敌情消失时侦察或移动到此前已知位置。"
	+ "train_queue 和人口预留表示已下达的生产，避免重复下单。command_result.ok 仅表示指令接受，reason 是拒绝原因，需修正下一步。"
)


static func assemble(
	observation: Dictionary,
	events: Array,
	meta: Dictionary = {},
	_history: Array = []
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
	}
	var messages: Array = [{"role": "system", "content": SYSTEM_PROMPT}]
	# The Python service owns per-team strategic memory; old client history is ignored.
	messages.append({"role": "user", "content": render_user(observation, events, metadata)})
	return {
		"model": SERVICE_MODEL,
		"stream": false,
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
		"对局 tick=%d 时间=%.1fs 文明=%s 己方team=%d 敌方team=%d（自主判断阶段）"
		% [
			int(metadata.get("tick", 0)),
			float(metadata.get("time_sec", 0.0)),
			String(metadata.get("team_label", metadata.get("profile_id", ""))),
			int(metadata.get("team", observation.get("team", 0))),
			int(metadata.get("enemy_team", 1)),
		]
	)
	lines.append(
		"经济：食物=%d 木材=%d 黄金=%d 石头=%d 人口=%d+预留%d/%d"
		% [
			int(econ.get("food", 0)),
			int(econ.get("wood", 0)),
			int(econ.get("gold", 0)),
			int(econ.get("stone", 0)),
			int(econ.get("pop_used", 0)),
			int(econ.get("pop_reserved", 0)),
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
	var buildings: Array = []
	for ent in entities:
		if not (ent is Dictionary):
			continue
		var kind := String((ent as Dictionary).get("kind", ""))
		if kind == "unit":
			unit_bits.append(
				"id=%d team=%d %s hp=%.0f/%.0f 指令=%s target_id=%s 坐标=%s move_goal=%s gather=%s/%s carry=%s:%.0f stuck=%d"
				% [
					int(ent.get("id", -1)),
					int(ent.get("team", -1)),
					String(ent.get("def_id", "")),
					float(ent.get("hp", 0)),
					float(ent.get("max_hp", 0)),
					String(ent.get("order", "NONE")),
					str(ent.get("target_id")),
					_fmt_pos(ent.get("pos", [])),
					_fmt_pos(ent.get("move_goal")),
					str(ent.get("gather_resource_type")),
					String(ent.get("gather_state", "")),
					str(ent.get("carry_type")),
					float(ent.get("carry_amount", 0)),
					int(ent.get("stuck_frames", 0)),
				]
			)
		elif kind == "building":
			buildings.append(ent)
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
	lines.append("建筑（显式team，己方包含施工/生产队列/可训练兵种/研究条件）：" + JSON.stringify(buildings))
	lines.append("地图边界：" + JSON.stringify(observation.get("map_bounds", {})))
	lines.append("时代与已研究科技：" + JSON.stringify(observation.get("progression", {})))
	lines.append("决策上下文（真实目录、合法建造候选、己方探索边缘与可见战况）：" + JSON.stringify(observation.get("decision_context", {})))
	if events.is_empty():
		lines.append("自上一 tick 事件：（无）")
	else:
		var ev_bits: PackedStringArray = PackedStringArray()
		for ev in events:
			if ev is Dictionary:
				var eid := int((ev as Dictionary).get("entity_id", -1))
				ev_bits.append("%s#%d" % [String(ev.get("type", "event")), eid])
		lines.append("自上一 tick 事件：" + ", ".join(ev_bits))
		lines.append("事件详情（包括指令拒绝原因）：" + JSON.stringify(events))
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
