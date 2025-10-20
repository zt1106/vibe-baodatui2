extends RefCounted

const LobbyUtils = preload("res://scripts/lobby_utils.gd")

signal ready_pressed
signal leave_pressed
signal config_apply_pressed

var detail_label: RichTextLabel = null
var container: Control = null
var title_label: Label = null
var state_label: Label = null
var status_label: Label = null
var players_list: ItemList = null
var ready_button: Button = null
var leave_button: Button = null
var config_limit: SpinBox = null
var config_apply_button: Button = null
var config_hint_label: Label = null

var _current_detail: Dictionary = {}
var _current_config_limit: int = 0
var _config_dirty: bool = false
var _suppress_config_signal: bool = false
var _last_context: Dictionary = {}


func setup(nodes: Dictionary) -> void:
	detail_label = nodes.get("detail_label", null)
	container = nodes.get("container", null)
	title_label = nodes.get("title_label", null)
	state_label = nodes.get("state_label", null)
	status_label = nodes.get("status_label", null)
	players_list = nodes.get("players_list", null)
	ready_button = nodes.get("ready_button", null)
	leave_button = nodes.get("leave_button", null)
	config_limit = nodes.get("config_limit", null)
	config_apply_button = nodes.get("config_apply_button", null)
	config_hint_label = nodes.get("config_hint_label", null)

	if ready_button:
		ready_button.disabled = true
		ready_button.pressed.connect(_on_ready_pressed)
	if leave_button:
		leave_button.disabled = true
		leave_button.pressed.connect(_on_leave_pressed)
	if config_apply_button:
		config_apply_button.disabled = true
		config_apply_button.pressed.connect(_on_config_apply_pressed)
	if config_limit:
		config_limit.editable = false
		config_limit.value_changed.connect(_on_config_limit_value_changed)

	reset_controls()
	reset_summary()


func reset_summary() -> void:
	if detail_label:
		detail_label.bbcode_text = "选择一个房间查看详情。"


func render_summary(summary: Variant) -> void:
	if detail_label == null:
		return
	if typeof(summary) != TYPE_DICTIONARY:
		reset_summary()
		return
	var room_id := _to_int(summary.get("id", -1), -1)
	var room_label := LobbyUtils.escape_bbcode(_format_room_label(room_id))
	var state := LobbyUtils.format_room_state(str(summary.get("state", "")))
	var players := _to_int(summary.get("players", summary.get("player_count", 0)), 0)
	var limit := _to_int(summary.get("player_limit", players), players)
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % room_label)
	lines.append("状态：%s" % state)
	lines.append("玩家：%d/%d" % [players, limit])
	detail_label.bbcode_text = "\n".join(lines)


func render_detail(detail: Variant) -> void:
	if detail_label == null or typeof(detail) != TYPE_DICTIONARY:
		reset_summary()
		return
	var room_id := _to_int(detail.get("id", -1), -1)
	var room_label := LobbyUtils.escape_bbcode(_format_room_label(room_id))
	var state := LobbyUtils.format_room_state(str(detail.get("state", "")))
	var players: Array = detail.get("players", [])
	var limit := _to_int(detail.get("player_limit", players.size()), players.size())
	var config: Variant = detail.get("config", null)
	if typeof(config) == TYPE_DICTIONARY:
		limit = _to_int(config.get("player_limit", limit), limit)
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % room_label)
	lines.append("状态：%s" % state)
	lines.append("玩家：%d/%d" % [players.size(), limit])
	for player_data in players:
		if typeof(player_data) != TYPE_DICTIONARY:
			continue
		var player_name := LobbyUtils.escape_bbcode(str(player_data.get("username", "未知")))
		var role := "[b](房主)[/b] " if player_data.get("is_host", false) else ""
		var ready_state := LobbyUtils.format_player_state(str(player_data.get("state", "")))
		lines.append("%s%s [%s]" % [role, player_name, ready_state])
	detail_label.bbcode_text = "\n".join(lines)


func show() -> void:
	if container:
		container.visible = true


func hide() -> void:
	if container:
		container.visible = false


func is_visible() -> bool:
	return container != null and container.visible


func reset_controls() -> void:
	if title_label:
		title_label.text = "房间"
	if state_label:
		state_label.text = ""
	if status_label:
		status_label.text = ""
		status_label.modulate = Color(1, 1, 1)
	if players_list:
		players_list.clear()
	if ready_button:
		ready_button.disabled = true
		ready_button.text = "准备"
	if leave_button:
		leave_button.disabled = true
	var default_limit := 0
	if config_limit:
		_suppress_config_signal = true
		default_limit = _to_int(config_limit.min_value, 2)
		if default_limit < 2:
			default_limit = 2
		config_limit.value = default_limit
		_suppress_config_signal = false
		config_limit.editable = false
	if config_apply_button:
		config_apply_button.disabled = true
	if config_hint_label:
		config_hint_label.text = "只有房主可以修改设置。"
	_current_detail.clear()
	_current_config_limit = default_limit
	_config_dirty = false
	_last_context = {}


func update_room_view(detail: Dictionary, context: Dictionary, store_detail: bool = true) -> void:
	if store_detail:
		_current_detail = detail.duplicate(true)
	var effective_detail := detail if !store_detail else _current_detail
	if effective_detail.is_empty():
		reset_controls()
		_last_context = {
			"mock_mode": bool(context.get("mock_mode", false)),
			"is_host": false,
			"room_state": "waiting",
			"room_config_inflight": bool(context.get("room_config_inflight", false))
		}
		return

	var user_id := _to_int(context.get("user_id", -1), -1)
	var mock_mode := bool(context.get("mock_mode", false))
	var ready_inflight := bool(context.get("room_ready_inflight", false))
	var leave_inflight := bool(context.get("room_leave_inflight", false))
	var config_inflight := bool(context.get("room_config_inflight", false))

	var room_id := _to_int(effective_detail.get("id", -1), -1)
	var room_label := _format_room_label(room_id)
	var room_state := str(effective_detail.get("state", "waiting"))
	var players: Array = effective_detail.get("players", [])
	var limit := players.size()
	var config: Variant = effective_detail.get("config", null)
	if typeof(config) == TYPE_DICTIONARY:
		limit = _to_int(config.get("player_limit", limit), limit)
	else:
		limit = _to_int(effective_detail.get("player_limit", limit), limit)
	_current_config_limit = limit

	if title_label:
		title_label.text = room_label
	if state_label:
		state_label.text = "状态：%s    玩家：%d/%d" % [LobbyUtils.format_room_state(room_state), players.size(), limit]

	if players_list:
		players_list.clear()
		for entry in players:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			players_list.add_item(_format_room_player_entry(entry, user_id))

	var current_player := _get_current_player_entry(effective_detail, user_id)
	var current_state := str(current_player.get("state", "not_prepared"))
	var ready_text := "取消准备" if current_state == "prepared" else "准备"
	var can_ready := !mock_mode and room_state == "waiting" and !ready_inflight and !current_player.is_empty()
	if ready_button:
		ready_button.text = ready_text
		ready_button.disabled = !can_ready

	if leave_button:
		leave_button.disabled = leave_inflight or mock_mode

	var is_host := _is_current_user_host(effective_detail, user_id)
	var can_edit_config := is_host and !mock_mode and !config_inflight and room_state == "waiting"
	if config_limit and (! _config_dirty or store_detail):
		_suppress_config_signal = true
		config_limit.value = limit
		_suppress_config_signal = false
	if config_limit:
		config_limit.editable = can_edit_config

	if store_detail:
		_config_dirty = false

	if config_apply_button:
		var can_apply := can_edit_config and _config_dirty
		config_apply_button.disabled = !can_apply
	if config_hint_label:
		config_hint_label.text = "你是房主，可以调整设置。" if is_host else "只有房主可以修改设置。"

	_last_context = {
		"mock_mode": mock_mode,
		"is_host": is_host,
		"room_state": room_state,
		"room_config_inflight": config_inflight
	}


func refresh_room_view(context: Dictionary) -> void:
	update_room_view(_current_detail, context, false)


func set_status(message: String, is_error: bool) -> void:
	if status_label == null:
		return
	var color := Color(0.95, 0.54, 0.54) if is_error else Color(1, 1, 1)
	status_label.modulate = color
	status_label.text = message


func set_ready_button_disabled(disabled: bool) -> void:
	if ready_button:
		ready_button.disabled = disabled


func set_leave_button_disabled(disabled: bool) -> void:
	if leave_button:
		leave_button.disabled = disabled


func set_config_apply_disabled(disabled: bool) -> void:
	if config_apply_button:
		config_apply_button.disabled = disabled


func has_room_detail() -> bool:
	return !_current_detail.is_empty()


func get_room_detail() -> Dictionary:
	return _current_detail


func clear_room_detail() -> void:
	_current_detail.clear()
	_current_config_limit = 0
	_config_dirty = false


func current_player_entry(user_id: int) -> Dictionary:
	return _get_current_player_entry(_current_detail, user_id)


func is_current_user_host(user_id: int) -> bool:
	return _is_current_user_host(_current_detail, user_id)


func has_config_dirty() -> bool:
	return _config_dirty


func set_config_dirty(dirty: bool) -> void:
	_config_dirty = dirty
	_refresh_config_controls()


func get_current_config_limit() -> int:
	return _current_config_limit


func get_config_limit_value() -> int:
	if config_limit:
		return _to_int(config_limit.value, _current_config_limit)
	return _current_config_limit


func set_config_inflight(is_inflight: bool) -> void:
	_last_context["room_config_inflight"] = is_inflight
	_refresh_config_controls()


func _to_int(value: Variant, default_value: int = 0) -> int:
	match typeof(value):
		TYPE_NIL:
			return default_value
		TYPE_BOOL:
			return 1 if value else 0
		TYPE_INT:
			return value
		TYPE_FLOAT:
			return int(value)
		TYPE_STRING:
			var s: String = value
			return s.to_int() if s.is_valid_int() else default_value
		TYPE_ARRAY:
			var arr: Array = value
			return arr.size()
		_:
			return default_value


func _refresh_config_controls() -> void:
	var can_edit_config := _can_edit_config()
	if config_limit:
		config_limit.editable = can_edit_config
	if config_apply_button:
		var can_apply := can_edit_config and _config_dirty
		config_apply_button.disabled = !can_apply


func _can_edit_config() -> bool:
	if _last_context.is_empty():
		return false
	if bool(_last_context.get("mock_mode", false)):
		return false
	if bool(_last_context.get("room_config_inflight", false)):
		return false
	if !_last_context.get("is_host", false):
		return false
	return _last_context.get("room_state", "waiting") == "waiting"


func _on_ready_pressed() -> void:
	emit_signal("ready_pressed")


func _on_leave_pressed() -> void:
	emit_signal("leave_pressed")


func _on_config_apply_pressed() -> void:
	emit_signal("config_apply_pressed")


func _on_config_limit_value_changed(value: float) -> void:
	if _suppress_config_signal:
		return
	var new_limit := _to_int(value, _current_config_limit)
	_config_dirty = new_limit != _current_config_limit
	_refresh_config_controls()


func _format_room_player_entry(entry: Dictionary, viewer_user_id: int) -> String:
	var name := str(entry.get("username", "玩家"))
	var user_id := _to_int(entry.get("user_id", -1), -1)
	var tags: Array[String] = []
	if user_id == viewer_user_id:
		tags.append("你")
	if entry.get("is_host", false):
		tags.append("房主")
	var prefix := ""
	if !tags.is_empty():
		prefix = "[%s] " % ",".join(tags)
	var ready_state := LobbyUtils.format_player_state(str(entry.get("state", "")))
	return "%s%s · %s" % [prefix, name, ready_state]


func _format_room_label(room_id: int) -> String:
	if room_id <= 0:
		return "房间"
	return "房间 %d" % room_id


func _get_current_player_entry(detail: Dictionary, user_id: int) -> Dictionary:
	var players: Variant = detail.get("players", [])
	if typeof(players) != TYPE_ARRAY:
		return {}
	for entry in players:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if _to_int(entry.get("user_id", -1), -1) == user_id:
			return entry
	return {}


func _is_current_user_host(detail: Dictionary, user_id: int) -> bool:
	return _to_int(detail.get("host_id", -1), -1) == user_id
