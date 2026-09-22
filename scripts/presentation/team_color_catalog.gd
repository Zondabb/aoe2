class_name TeamColorCatalog
extends RefCounted

## Palette ids are 1-based SLP player rows, independent of civilization.
const MIN_COLOR_ID := 1
const MAX_COLOR_ID := 8
const DEFAULT_PLAYER_COLOR_ID := 1
const DEFAULT_AI_COLOR_ID := 2
const FALLBACK_COLORS := [
	Color(0.18, 0.42, 0.95), Color(0.88, 0.18, 0.14),
	Color(0.20, 0.75, 0.25), Color(0.95, 0.85, 0.15),
	Color(0.20, 0.85, 0.85), Color(0.75, 0.25, 0.80),
	Color(0.55, 0.55, 0.55), Color(0.95, 0.50, 0.10),
]


static func is_valid_color_id(color_id: int) -> bool:
	return color_id >= MIN_COLOR_ID and color_id <= MAX_COLOR_ID


static func default_color_id(team: int) -> int:
	return DEFAULT_AI_COLOR_ID if team == Enums.Team.AI else DEFAULT_PLAYER_COLOR_ID


static func resolve_color_id(team: int, match_state: Object = null) -> int:
	if match_state != null and match_state.has_method("get_team_color_id"):
		var color_id := int(match_state.call("get_team_color_id", team))
		if is_valid_color_id(color_id):
			return color_id
	return default_color_id(team)


static func fallback_color(color_id: int) -> Color:
	return FALLBACK_COLORS[clampi(color_id, MIN_COLOR_ID, MAX_COLOR_ID) - 1]
