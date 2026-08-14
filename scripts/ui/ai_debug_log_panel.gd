extends RichTextLabel

const AiDecisionLogScript := preload("res://scripts/systems/ai/ai_decision_log.gd")

var decision_log: AiDecisionLog
var _bound := false


func setup(log: AiDecisionLog) -> void:
	decision_log = log
	if decision_log == null:
		return
	if not _bound:
		decision_log.add_listener(_on_entry_added)
		_bound = true
	for line in decision_log.entries:
		_append_line(line)


func _on_entry_added(line: String) -> void:
	_append_line(line)


func _append_line(line: String) -> void:
	append_text(line + "\n")
	while get_line_count() > 180:
		remove_paragraph(0)
	scroll_to_line(get_line_count())
