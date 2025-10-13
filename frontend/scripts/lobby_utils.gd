extends RefCounted
class_name LobbyUtils

static func escape_bbcode(text: String) -> String:
	return text.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")

static func format_room_state(state: String) -> String:
	match state:
		"waiting":
			return "等待玩家"
		"in_game":
			return "进行中"
		_:
			return state.capitalize()

static func format_player_state(state: String) -> String:
	match state:
		"prepared":
			return "已准备"
		"not_prepared":
			return "未准备"
		_:
			return state.capitalize()


