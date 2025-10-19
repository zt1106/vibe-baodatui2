extends Node

const LobbyUtils = preload("res://scripts/lobby_utils.gd")
const RandomNickname = preload("res://scripts/random_nickname.gd")
const MockData = preload("res://scripts/mock_data.gd")

@export var websocket_url: String = "ws://127.0.0.1:7998/"
@export var timeout_seconds: float = 3.0

var _client: WebSocketPeer = WebSocketPeer.new()
var _connected: bool = false
var _elapsed: float = 0.0
var _connecting: bool = false

signal connection_succeeded
signal connection_failed

var _error_dialog: AcceptDialog = null
var _login_container: Control = null
var _login_panel: Control = null
var _lobby_container: Control = null
var _nickname_input: LineEdit = null
var _join_button: Button = null
var _generate_nickname_button: Button = null
var _refresh_rooms_button: Button = null
var _join_room_button: Button = null
var _room_list: ItemList = null
var _player_limit: SpinBox = null
var _create_room_button: Button = null
var _lobby_status_label: Label = null
var _user_info_label: Label = null
var _room_detail_label: RichTextLabel = null
var _mock_lobby_button: Button = null
var _room_view_container: Control = null
var _room_view_title_label: Label = null
var _room_view_state_label: Label = null
var _room_view_status_label: Label = null
var _room_view_players_list: ItemList = null
var _room_view_ready_button: Button = null
var _room_view_leave_button: Button = null
var _room_view_config_limit: SpinBox = null
var _room_view_config_apply_button: Button = null
var _room_view_config_hint: Label = null
var _poker_chips: Array[ColorRect] = []
var _animation_time: float = 0.0


var _request_id_seq: int = 0
var _pending_requests: Dictionary = {}
var _rooms: Dictionary = {}
var _current_room_detail: Dictionary = {}
var _current_room_config_limit: int = 0
var _user_id: int = -1
var _username: String = ""
var _room_list_inflight: bool = false
var _room_join_inflight: bool = false
var _room_create_inflight: bool = false
var _room_leave_inflight: bool = false
var _room_ready_inflight: bool = false
var _room_config_inflight: bool = false
var _room_config_dirty: bool = false
var _suppress_config_signal: bool = false
var _mock_mode: bool = false


func _pending_key(value: Variant) -> String:
	if value == null:
		return ""
	var type := typeof(value)
	match type:
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			var as_float: float = value
			var as_int := int(as_float)
			if is_equal_approx(as_float, float(as_int)):
				return str(as_int)
			return str(as_float)
		TYPE_STRING:
			return str(value)
		_:
			return str(value)

func _enter_online_lobby() -> void:
	_mock_mode = false
	_clear_room_state()
	_reset_room_view_controls()
	_show_lobby_view()
	_set_lobby_status("正在加载房间...", false)
	_request_room_list()


func _ready() -> void:
	RandomNickname.init()
	_cache_ui_nodes()
	_update_login_panel_size()
	get_viewport().size_changed.connect(_on_viewport_resized)
	_show_login_view()
	_attempt_connection()
	_start_background_animation()

func _cache_ui_nodes() -> void:
	_error_dialog = get_node_or_null("ErrorDialog") as AcceptDialog
	_login_container = get_node_or_null("CenterContainer") as Control
	_login_panel = get_node_or_null("CenterContainer/Panel") as Control
	_lobby_container = get_node_or_null("Lobby") as Control
	_nickname_input = get_node_or_null("CenterContainer/Panel/MarginContainer/VBox/Form/NicknameInput") as LineEdit
	_join_button = get_node_or_null("CenterContainer/Panel/MarginContainer/VBox/Form/JoinButton") as Button
	_generate_nickname_button = get_node_or_null("CenterContainer/Panel/MarginContainer/VBox/Form/RandomNicknameButton") as Button
	_mock_lobby_button = get_node_or_null("CenterContainer/Panel/MarginContainer/VBox/Form/MockLobbyButton") as Button
	_user_info_label = get_node_or_null("Lobby/MarginContainer/LobbyVBox/UserRow/UserInfoLabel") as Label
	_refresh_rooms_button = get_node_or_null("Lobby/MarginContainer/LobbyVBox/UserRow/RefreshRoomsButton") as Button
	_lobby_status_label = get_node_or_null("Lobby/MarginContainer/LobbyVBox/LobbyStatusLabel") as Label
	_room_list = get_node_or_null("Lobby/MarginContainer/LobbyVBox/RoomPanel/RoomPanelMargin/RoomPanelVBox/RoomList") as ItemList
	_join_room_button = get_node_or_null("Lobby/MarginContainer/LobbyVBox/RoomPanel/RoomPanelMargin/RoomPanelVBox/RoomActions/JoinRoomButton") as Button
	_room_detail_label = get_node_or_null("Lobby/MarginContainer/LobbyVBox/RoomPanel/RoomPanelMargin/RoomPanelVBox/RoomDetailLabel") as RichTextLabel
	_player_limit = get_node_or_null("Lobby/MarginContainer/LobbyVBox/CreateRoomRow/PlayerLimit") as SpinBox
	_create_room_button = get_node_or_null("Lobby/MarginContainer/LobbyVBox/CreateRoomRow/CreateRoomButton") as Button
	_room_view_container = get_node_or_null("RoomView") as Control
	_room_view_title_label = get_node_or_null("RoomView/MarginContainer/RoomVBox/RoomTitle") as Label
	_room_view_state_label = get_node_or_null("RoomView/MarginContainer/RoomVBox/RoomStateLabel") as Label
	_room_view_status_label = get_node_or_null("RoomView/MarginContainer/RoomVBox/RoomStatusLabel") as Label
	_room_view_players_list = get_node_or_null("RoomView/MarginContainer/RoomVBox/ContentRow/PlayersColumn/PlayersList") as ItemList
	_room_view_ready_button = get_node_or_null("RoomView/MarginContainer/RoomVBox/ContentRow/ActionsColumn/ReadyButton") as Button
	_room_view_leave_button = get_node_or_null("RoomView/MarginContainer/RoomVBox/ContentRow/ActionsColumn/LeaveButton") as Button
	_room_view_config_limit = get_node_or_null("RoomView/MarginContainer/RoomVBox/ContentRow/ActionsColumn/ConfigPanel/PlayerLimitSpin") as SpinBox
	_room_view_config_apply_button = get_node_or_null("RoomView/MarginContainer/RoomVBox/ContentRow/ActionsColumn/ConfigPanel/ApplyConfigButton") as Button
	_room_view_config_hint = get_node_or_null("RoomView/MarginContainer/RoomVBox/ContentRow/ActionsColumn/ConfigPanel/ConfigHint") as Label

	# Cache poker chip nodes for animation
	_poker_chips.append(get_node_or_null("PokerChip1") as ColorRect)
	_poker_chips.append(get_node_or_null("PokerChip2") as ColorRect)
	_poker_chips.append(get_node_or_null("PokerChip3") as ColorRect)

	if _error_dialog:
		connection_failed.connect(_on_connection_failed)
	connection_succeeded.connect(_on_connection_succeeded)

	if _join_button:
		_join_button.disabled = true
		_join_button.pressed.connect(_on_join_button_pressed)
	if _generate_nickname_button:
		_generate_nickname_button.pressed.connect(_on_generate_nickname_pressed)
	if _mock_lobby_button:
		_mock_lobby_button.pressed.connect(_on_mock_lobby_button_pressed)
	if _nickname_input:
		_nickname_input.text_submitted.connect(_on_nickname_submitted)

	if _refresh_rooms_button:
		_refresh_rooms_button.pressed.connect(_on_refresh_rooms_pressed)
	if _room_list:
		_room_list.item_selected.connect(_on_room_selected)
		_room_list.item_activated.connect(_on_room_activated)
	if _join_room_button:
		_join_room_button.disabled = true
		_join_room_button.pressed.connect(_on_join_room_pressed)
	if _create_room_button:
		_create_room_button.pressed.connect(_on_create_room_pressed)
	if _room_detail_label:
		_room_detail_label.bbcode_text = "选择一个房间查看详情。"

func _update_login_panel_size() -> void:
	if not _login_panel:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var target_width := viewport_size.x * 0.6
	var target_height := viewport_size.y * 0.75
	target_width = clamp(target_width, 900.0, 1600.0)
	target_height = clamp(target_height, 660.0, 1100.0)
	_login_panel.custom_minimum_size = Vector2(target_width, target_height)

func _on_viewport_resized() -> void:
	_update_login_panel_size()

func _process(delta: float) -> void:
	if _mock_mode:
		return
	if _connecting:
		_elapsed += delta
		if _elapsed >= timeout_seconds:
			_connecting = false
			_connected = false
			_client.close()
			emit_signal("connection_failed")

	_client.poll()

	var state := _client.get_ready_state()
	match state:
		WebSocketPeer.STATE_CONNECTING:
			pass
		WebSocketPeer.STATE_OPEN:
			if _connecting:
				_on_handshake_completed()
			_process_incoming_messages()
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			if _connecting:
				_on_connection_error()
			elif _connected:
				_on_connection_closed()

	# Animate background poker chips
	_animate_poker_chips(delta)

func _process_incoming_messages() -> void:
	while _client.get_available_packet_count() > 0:
		var packet: PackedByteArray = _client.get_packet()
		if _client.get_packet_error() != OK:
			continue
		var message := packet.get_string_from_utf8()
		_handle_incoming_message(message)

func _attempt_connection() -> void:
	if _mock_mode:
		return
	_elapsed = 0.0
	_connecting = true
	_connected = false
	_request_id_seq = 0
	_pending_requests.clear()
	_rooms.clear()
	_clear_room_state()
	_room_leave_inflight = false
	_room_ready_inflight = false
	_room_config_inflight = false
	_client = WebSocketPeer.new()
	_reset_room_view_controls()
	_hide_room_view()
	var err := _client.connect_to_url(websocket_url)
	if err != OK:
		_connecting = false
		emit_signal("connection_failed")

func _on_handshake_completed() -> void:
	_connecting = false
	_connected = true
	emit_signal("connection_succeeded")

func _on_connection_closed() -> void:
	if _mock_mode:
		return
	_connected = false
	_pending_requests.clear()
	_room_list_inflight = false
	_room_join_inflight = false
	_room_create_inflight = false
	_room_leave_inflight = false
	_room_ready_inflight = false
	_room_config_inflight = false
	if _join_button:
		_join_button.disabled = true
	_clear_room_state()
	_reset_room_view_controls()
	_set_lobby_status("已与服务器断开连接，正在重新连接...", true)
	_show_login_view()
	call_deferred("_attempt_connection")

func _on_connection_error() -> void:
	if _mock_mode:
		return
	_connecting = false
	_connected = false
	emit_signal("connection_failed")

func _on_connection_failed() -> void:
	if _mock_mode:
		return
	if _join_button:
		_join_button.disabled = true
	if _error_dialog:
		_error_dialog.popup_centered()

func _on_connection_succeeded() -> void:
	if _mock_mode:
		return
	if _join_button:
		_join_button.disabled = false
	if _nickname_input:
		_nickname_input.grab_focus()
	_set_lobby_status("", false)

func _handle_incoming_message(raw: String) -> void:
	var json := JSON.new()
	var parse_error := json.parse(raw)
	if parse_error != OK:
		push_warning("无法解析服务器消息：%s" % raw)
		return
	var data: Variant = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.has("method"):
		_handle_notification(data)
	elif data.has("result"):
		_handle_response(data)
	elif data.has("error"):
		_handle_error_response(data)

func _handle_notification(envelope: Dictionary) -> void:
	var method := str(envelope.get("method", ""))
	var params: Variant = envelope.get("params", {})
	match method:
		"system":
			_handle_system_notification(params)
		_:
			pass

func _handle_system_notification(payload: Variant) -> void:
	if typeof(payload) != TYPE_DICTIONARY:
		return
	var code := str(payload.get("code", ""))
	var message := str(payload.get("message", ""))
	if code == "connected":
		return
	_set_lobby_status(message, code != "info")

func _handle_response(envelope: Dictionary) -> void:
	if !envelope.has("id"):
		return
	var id_value: Variant = envelope.get("id")
	if id_value == null:
		return
	var key := _pending_key(id_value)
	if !_pending_requests.has(key):
		return
	var pending: Dictionary = _pending_requests[key]
	_pending_requests.erase(key)
	var result: Variant = envelope.get("result")
	var on_success: Callable = pending.get("success", Callable())
	if on_success.is_valid():
		on_success.call(result)

func _handle_error_response(envelope: Dictionary) -> void:
	var error_info: Variant = envelope.get("error", {})
	var id_value: Variant = envelope.get("id")
	var pending: Dictionary = {}
	if id_value != null:
		var key := _pending_key(id_value)
		if _pending_requests.has(key):
			pending = _pending_requests[key]
			_pending_requests.erase(key)
	var message := "请求失败。"
	var code := -1
	var extra: Dictionary = {}
	if typeof(error_info) == TYPE_DICTIONARY:
		message = str(error_info.get("message", message))
		code = int(error_info.get("code", code))
		extra = error_info.duplicate(true)
	else:
		extra = {"message": message, "code": code}
	extra["message"] = message
	extra["code"] = code
	if typeof(pending) == TYPE_DICTIONARY and pending.has("method"):
		extra["method"] = pending["method"]
	var on_error: Callable = Callable()
	if typeof(pending) == TYPE_DICTIONARY:
		on_error = pending.get("failure", Callable())
	if on_error.is_valid():
		on_error.call(extra)
	else:
		_set_lobby_status(message, true)

func _send_request(method: String, params: Dictionary, on_success: Callable, on_failure: Callable = Callable()) -> void:
	if _mock_mode:
		if on_failure.is_valid():
			on_failure.call({
				"code": ERR_UNAVAILABLE,
				"message": "离线预览模式不会连接服务器。",
				"method": method,
			})
		_set_lobby_status("离线预览：服务器操作已禁用。", true)
		return
	if !_connected:
		if on_failure.is_valid():
			on_failure.call({"code": ERR_CONNECTION_ERROR, "message": "尚未连接到服务器。", "method": method})
		_show_error("你尚未连接到服务器。")
		return
	_request_id_seq += 1
	var request_id := _request_id_seq
	var pending_key := _pending_key(request_id)
	var payload := {
		"jsonrpc": "2.0",
		"id": request_id,
		"method": method,
		"params": params.duplicate(true),
	}
	var encoded := JSON.stringify(payload)
	var err := _client.send_text(encoded)
	if err != OK:
		if on_failure.is_valid():
			on_failure.call({"code": err, "message": "请求发送失败。", "method": method})
		_show_error("无法连接到服务器。")
		return
	_pending_requests[pending_key] = {
		"success": on_success,
		"failure": on_failure,
		"method": method,
	}

func _on_join_button_pressed() -> void:
	if !_connected:
		_show_error("仍在连接服务器，请稍候。")
		return
	if _nickname_input == null or _join_button == null:
		return
	var nickname := _nickname_input.text.strip_edges()
	if nickname.is_empty():
		_show_error("请先输入显示名称，再继续。")
		_nickname_input.grab_focus()
		return
	_join_button.disabled = true
	_nickname_input.editable = false
	_send_request(
		"user_set_name",
		{"nickname": nickname},
		Callable(self, "_on_user_set_name_success"),
		Callable(self, "_on_user_set_name_error")
	)

func _on_nickname_submitted(_text: String) -> void:
	if _join_button and _join_button.disabled:
		return
	_on_join_button_pressed()

func _on_generate_nickname_pressed() -> void:
	if _nickname_input == null:
		return
	if !_nickname_input.editable:
		return
	var nickname: String = RandomNickname.generate()
	_nickname_input.text = nickname
	_nickname_input.caret_column = nickname.length()
	_nickname_input.select_all()
	_nickname_input.grab_focus()

func _on_mock_lobby_button_pressed() -> void:
	_enter_mock_lobby()

func _enter_mock_lobby() -> void:
	_mock_mode = true
	_connecting = false
	_connected = false
	_elapsed = 0.0
	_pending_requests.clear()
	_rooms.clear()
	_current_room_detail.clear()
	_request_id_seq = 0
	_room_list_inflight = false
	_room_join_inflight = false
	_room_create_inflight = false
	_room_leave_inflight = false
	_room_ready_inflight = false
	_room_config_inflight = false
	_room_config_dirty = false
	var state := _client.get_ready_state()
	if state == WebSocketPeer.STATE_CONNECTING or state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CLOSING:
		_client.close()
	_client = WebSocketPeer.new()
	if _join_button:
		_join_button.disabled = true
	if _generate_nickname_button:
		_generate_nickname_button.disabled = true
	if _nickname_input:
		_nickname_input.editable = false
	var preview_name := ""
	if _nickname_input:
		preview_name = _nickname_input.text.strip_edges()
	if preview_name.is_empty():
		preview_name = "游客"
	_username = preview_name
	_user_id = -1
	_show_lobby_view()
	if _user_info_label:
		_user_info_label.text = "当前登录：%s（离线预览）" % preview_name
	var rooms: Array = MockData.build_mock_rooms()
	_update_room_list({"rooms": rooms})
	if _room_list and _room_list.get_item_count() > 0:
		_room_list.select(0)
		var metadata: Variant = _room_list.get_item_metadata(0)
		if typeof(metadata) == TYPE_DICTIONARY:
			_render_room_summary(metadata)
			if metadata.has("players"):
				_render_room_detail(metadata)
	_set_lobby_status("离线预览：服务器操作已禁用。", false)
	_reset_room_view_controls()
	_hide_room_view()
	if _refresh_rooms_button:
		_refresh_rooms_button.disabled = true
	if _create_room_button:
		_create_room_button.disabled = true
	if _player_limit:
		_player_limit.editable = false
	_join_room_button_disabled(true)

	if _room_view_ready_button:
		_room_view_ready_button.disabled = true
		_room_view_ready_button.pressed.connect(_on_ready_button_pressed)
	if _room_view_leave_button:
		_room_view_leave_button.disabled = true
		_room_view_leave_button.pressed.connect(_on_leave_room_pressed)
	if _room_view_config_apply_button:
		_room_view_config_apply_button.disabled = true
		_room_view_config_apply_button.pressed.connect(_on_room_config_apply_pressed)
	if _room_view_config_limit:
		_room_view_config_limit.editable = false
		_room_view_config_limit.value_changed.connect(_on_room_config_limit_changed)


func _on_user_set_name_success(result: Variant) -> void:
	if _nickname_input:
		_nickname_input.editable = true
	if _join_button:
		_join_button.disabled = false
	if typeof(result) != TYPE_DICTIONARY:
		_show_error("设置显示名称时收到异常响应。")
		return
	_user_id = int(result.get("id", -1))
	_username = str(result.get("username", ""))
	if _username.is_empty() and _nickname_input:
		_username = _nickname_input.text.strip_edges()
	if _user_info_label:
		if _user_id >= 0:
			_user_info_label.text = "当前登录：%s（#%d）" % [_username, _user_id]
		else:
			_user_info_label.text = "当前登录：%s" % _username
	_enter_online_lobby()

func _on_user_set_name_error(error_data: Dictionary) -> void:
	if _nickname_input:
		_nickname_input.editable = true
	if _join_button:
		_join_button.disabled = false
	var message := "无法设置显示名称。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_show_error(message)

func _on_refresh_rooms_pressed() -> void:
	if _mock_mode:
		_enter_mock_lobby()
		return
	_request_room_list()

func _request_room_list() -> void:
	if _mock_mode:
		_enter_mock_lobby()
		return
	if _room_list_inflight:
		return
	_room_list_inflight = true
	if _refresh_rooms_button:
		_refresh_rooms_button.disabled = true
	_set_lobby_status("正在加载房间...", false)
	_send_request(
		"room_list",
		{},
		Callable(self, "_on_room_list_success"),
		Callable(self, "_on_room_list_error")
	)

func _on_room_list_success(result: Variant) -> void:
	_room_list_inflight = false
	if _refresh_rooms_button:
		_refresh_rooms_button.disabled = false
	_update_room_list(result)

func _on_room_list_error(error_data: Dictionary) -> void:
	_room_list_inflight = false
	if _refresh_rooms_button:
		_refresh_rooms_button.disabled = false
	var message := "无法加载房间。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_set_lobby_status(message, true)

func _update_room_list(payload: Variant) -> void:
	if _room_list:
		_room_list.clear()
	_join_room_button_disabled(true)
	_rooms.clear()
	if _room_detail_label:
		_room_detail_label.bbcode_text = "选择一个房间查看详情。"
	if typeof(payload) != TYPE_DICTIONARY:
		_set_lobby_status("房间列表数据异常。", true)
		return
	var rooms: Array = payload.get("rooms", [])
	if typeof(rooms) != TYPE_ARRAY:
		_set_lobby_status("房间列表数据异常。", true)
		return
	if rooms.is_empty():
		_set_lobby_status("暂无房间，创建一个开始吧。", false)
		return
	for room_entry in rooms:
		if typeof(room_entry) != TYPE_DICTIONARY:
			continue
		var room_id_variant: Variant = room_entry.get("id", null)
		if room_id_variant == null:
			continue
		var room_id := int(room_id_variant)
		var room_label := _format_room_label(room_id)
		var player_count := int(room_entry.get("player_count", 0))
		var player_limit := int(room_entry.get("player_limit", 0))
		var state_text: String = LobbyUtils.format_room_state(str(room_entry.get("state", "")))
		var label := "%s • %d/%d • %s" % [room_label, player_count, player_limit, state_text]
		if _room_list:
			var index := _room_list.add_item(label)
			_room_list.set_item_metadata(index, room_entry.duplicate(true))
		_rooms[room_id] = room_entry.duplicate(true)
	_set_lobby_status("找到 %d 个房间。" % rooms.size(), false)
	if _room_list and _room_list.get_item_count() > 0:
		_room_list.select(0)
		_on_room_selected(0)

func _on_room_selected(index: int) -> void:
	if _room_list == null:
		return
	var metadata: Variant = _room_list.get_item_metadata(index)
	if _mock_mode:
		_join_room_button_disabled(true)
	else:
		_join_room_button_disabled(false)
	if typeof(metadata) == TYPE_DICTIONARY:
		_render_room_summary(metadata)
		if metadata.has("players"):
			_render_room_detail(metadata)

func _on_room_activated(index: int) -> void:
	_on_room_selected(index)
	_on_join_room_pressed()

func _on_join_room_pressed() -> void:
	if _mock_mode:
		_set_lobby_status("离线预览：无法加入房间。", true)
		return
	if _room_join_inflight:
		return
	if _room_list == null or !_room_list.is_anything_selected():
		_set_lobby_status("请选择要加入的房间。", true)
		return
	var selected := _room_list.get_selected_items()
	if selected.is_empty():
		_set_lobby_status("请选择要加入的房间。", true)
		return
	var index := selected[0]
	var metadata: Variant = _room_list.get_item_metadata(index)
	if typeof(metadata) != TYPE_DICTIONARY or !metadata.has("id"):
		_set_lobby_status("无法确定所选房间。", true)
		return
	var room_id := int(metadata["id"])
	_room_join_inflight = true
	_join_room_button_disabled(true)
	_set_lobby_status("正在加入房间...", false)
	_send_request(
		"room_join",
		{"room_id": room_id},
		Callable(self, "_on_room_join_success"),
		Callable(self, "_on_room_join_error")
	)

func _on_room_join_success(result: Variant) -> void:
	_room_join_inflight = false
	_join_room_button_disabled(false)
	if typeof(result) != TYPE_DICTIONARY:
		_reset_room_view_controls()
		_show_room_view()
		_set_room_view_status("已加入房间。", false)
		return
	_current_room_detail = result.duplicate(true)
	_reset_room_view_controls()
	_show_room_view()
	_update_room_view(_current_room_detail)
	var room_id := int(result.get("id", -1))
	var room_label := _format_room_label(room_id)
	_set_room_view_status("已加入%s。" % room_label, false)
	_set_lobby_status("", false)

func _on_room_join_error(error_data: Dictionary) -> void:
	_room_join_inflight = false
	_join_room_button_disabled(false)
	var message := "无法加入房间。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_set_lobby_status(message, true)

func _on_create_room_pressed() -> void:
	if _mock_mode:
		_set_lobby_status("离线预览：无法创建房间。", true)
		return
	if _room_create_inflight:
		return
	var limit := 4
	if _player_limit:
		limit = int(_player_limit.value)
	_room_create_inflight = true
	if _create_room_button:
		_create_room_button.disabled = true
	_set_lobby_status("正在创建房间...", false)
	_send_request(
		"room_create",
		{"player_limit": limit},
		Callable(self, "_on_room_create_success"),
		Callable(self, "_on_room_create_error")
	)

func _on_room_create_success(result: Variant) -> void:
	_room_create_inflight = false
	if _create_room_button:
		_create_room_button.disabled = false
	if typeof(result) != TYPE_DICTIONARY:
		_set_room_view_status("房间已创建。", false)
		_show_room_view()
		return
	_current_room_detail = result.duplicate(true)
	_reset_room_view_controls()
	_show_room_view()
	_update_room_view(_current_room_detail)
	var room_id := int(result.get("id", -1))
	var room_label := _format_room_label(room_id)
	_set_room_view_status("已创建并成为%s的房主。" % room_label, false)
	_set_lobby_status("", false)
	_request_room_list()

func _on_room_create_error(error_data: Dictionary) -> void:
	_room_create_inflight = false
	if _create_room_button:
		_create_room_button.disabled = false
	var message := "无法创建房间。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_set_lobby_status(message, true)

func _on_ready_button_pressed() -> void:
	if _mock_mode or _room_ready_inflight:
		return
	if _current_room_detail.is_empty():
		_set_room_view_status("尚未加入房间。", true)
		return
	var current_entry := _get_current_player_entry(_current_room_detail)
	if current_entry.is_empty():
		_set_room_view_status("未找到玩家信息。", true)
		return
	var current_state := str(current_entry.get("state", "not_prepared"))
	var target_prepared := current_state != "prepared"
	_room_ready_inflight = true
	if _room_view_ready_button:
		_room_view_ready_button.disabled = true
	_set_room_view_status("正在更新准备状态...", false)
	_send_request(
		"room_ready",
		{"prepared": target_prepared},
		Callable(self, "_on_room_ready_success"),
		Callable(self, "_on_room_ready_error")
	)

func _on_room_ready_success(result: Variant) -> void:
	_room_ready_inflight = false
	if typeof(result) == TYPE_DICTIONARY:
		_current_room_detail = result.duplicate(true)
		_update_room_view(_current_room_detail)
		var entry := _get_current_player_entry(_current_room_detail)
		var prepared := str(entry.get("state", "not_prepared")) == "prepared"
		var status_message := "你已准备就绪。" if prepared else "已取消准备状态。"
		_set_room_view_status(status_message, false)
	else:
		_set_room_view_status("准备状态已更新。", false)
	_update_room_view(_current_room_detail)

func _on_room_ready_error(error_data: Dictionary) -> void:
	_room_ready_inflight = false
	var message := "无法更新准备状态。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_set_room_view_status(message, true)
	_update_room_view(_current_room_detail)

func _on_leave_room_pressed() -> void:
	if _mock_mode:
		_set_room_view_status("离线预览：无法离开房间。", true)
		return
	if _room_leave_inflight:
		return
	_room_leave_inflight = true
	if _room_view_leave_button:
		_room_view_leave_button.disabled = true
	_set_room_view_status("正在离开房间...", false)
	_send_request(
		"room_leave",
		{},
		Callable(self, "_on_room_leave_success"),
		Callable(self, "_on_room_leave_error")
	)

func _clear_room_state() -> void:
	_current_room_detail.clear()
	_current_room_config_limit = 0
	_room_config_dirty = false

func _on_room_leave_success(_result: Variant) -> void:
	_room_leave_inflight = false
	_clear_room_state()
	_reset_room_view_controls()
	_hide_room_view()
	_show_lobby_view()
	_set_lobby_status("已离开房间。", false)
	_request_room_list()

func _on_room_leave_error(error_data: Dictionary) -> void:
	_room_leave_inflight = false
	var message := "无法离开房间。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_set_room_view_status(message, true)
	_update_room_view(_current_room_detail)

func _on_room_config_limit_changed(value: float) -> void:
	if _suppress_config_signal:
		return
	var new_limit := int(value)
	_room_config_dirty = new_limit != _current_room_config_limit
	if _room_view_config_apply_button:
		var can_apply := _room_config_dirty and !_room_config_inflight and _is_current_user_host(_current_room_detail) and !_mock_mode
		_room_view_config_apply_button.disabled = !can_apply

func _on_room_config_apply_pressed() -> void:
	if _mock_mode:
		_set_room_view_status("离线预览：无法更新配置。", true)
		return
	if _room_config_inflight or !_room_view_config_limit:
		return
	var new_limit := int(_room_view_config_limit.value)
	if !_room_config_dirty or new_limit == _current_room_config_limit:
		_set_room_view_status("没有需要保存的更改。", false)
		return
	_room_config_inflight = true
	_room_config_dirty = false
	if _room_view_config_apply_button:
		_room_view_config_apply_button.disabled = true
	_set_room_view_status("正在更新房间配置...", false)
	_send_request(
		"room_config_update",
		{"player_limit": new_limit},
		Callable(self, "_on_room_config_update_success"),
		Callable(self, "_on_room_config_update_error")
	)

func _on_room_config_update_success(result: Variant) -> void:
	_room_config_inflight = false
	if typeof(result) == TYPE_DICTIONARY:
		_current_room_detail = result.duplicate(true)
		_update_room_view(_current_room_detail)
		_set_room_view_status("房间配置已更新。", false)
	else:
		_set_room_view_status("房间配置已更新。", false)
	_update_room_view(_current_room_detail)

func _on_room_config_update_error(error_data: Dictionary) -> void:
	_room_config_inflight = false
	var message := "无法更新房间配置。"
	if typeof(error_data) == TYPE_DICTIONARY and error_data.has("message"):
		message = str(error_data["message"])
	_set_room_view_status(message, true)
	_update_room_view(_current_room_detail)

func _render_room_summary(summary: Variant) -> void:
	if _room_detail_label == null:
		return
	if typeof(summary) != TYPE_DICTIONARY:
		_room_detail_label.bbcode_text = "选择一个房间查看详情。"
		return
	var room_id := int(summary.get("id", -1))
	var room_label: String = LobbyUtils.escape_bbcode(_format_room_label(room_id))
	var state: String = LobbyUtils.format_room_state(str(summary.get("state", "")))
	var player_count := int(summary.get("player_count", 0))
	var player_limit := int(summary.get("player_limit", 0))
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % room_label)
	lines.append("状态：%s" % state)
	lines.append("玩家：%d/%d" % [player_count, player_limit])
	_room_detail_label.bbcode_text = "\n".join(lines)

func _render_room_detail(detail: Variant) -> void:
	if _room_detail_label == null or typeof(detail) != TYPE_DICTIONARY:
		return
	var room_id := int(detail.get("id", -1))
	var room_label: String = LobbyUtils.escape_bbcode(_format_room_label(room_id))
	var state: String = LobbyUtils.format_room_state(str(detail.get("state", "")))
	var players: Array = detail.get("players", [])
	var player_limit := players.size()
	var config: Variant = detail.get("config", null)
	if typeof(config) == TYPE_DICTIONARY:
		player_limit = int(config.get("player_limit", player_limit))
	else:
		player_limit = int(detail.get("player_limit", player_limit))
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % room_label)
	lines.append("状态：%s" % state)
	lines.append("玩家：%d/%d" % [players.size(), player_limit])
	for player_data in players:
		if typeof(player_data) != TYPE_DICTIONARY:
			continue
		var player_name: String = LobbyUtils.escape_bbcode(str(player_data.get("username", "未知")))
		var role := "[b](房主)[/b] " if player_data.get("is_host", false) else ""
		var ready_state: String = LobbyUtils.format_player_state(str(player_data.get("state", "")))
		lines.append("%s%s [%s]" % [role, player_name, ready_state])
	_room_detail_label.bbcode_text = "\n".join(lines)

func _show_room_view() -> void:
	if _login_container:
		_login_container.visible = false
	if _lobby_container:
		_lobby_container.visible = false
	if _room_view_container:
		_room_view_container.visible = true

func _hide_room_view() -> void:
	if _room_view_container:
		_room_view_container.visible = false

func _reset_room_view_controls() -> void:
	if _room_view_title_label:
		_room_view_title_label.text = "房间"
	if _room_view_state_label:
		_room_view_state_label.text = ""
	if _room_view_status_label:
		_room_view_status_label.text = ""
		_room_view_status_label.modulate = Color(1, 1, 1)
	if _room_view_players_list:
		_room_view_players_list.clear()
	if _room_view_ready_button:
		_room_view_ready_button.disabled = true
		_room_view_ready_button.text = "准备"
	if _room_view_leave_button:
		_room_view_leave_button.disabled = true
	var default_limit: int = 0
	if _room_view_config_limit:
		_suppress_config_signal = true
		default_limit = int(_room_view_config_limit.min_value)
		if default_limit < 2:
			default_limit = 2
		_room_view_config_limit.value = default_limit
		_suppress_config_signal = false
		_room_view_config_limit.editable = false
	else:
		default_limit = 0
	_current_room_config_limit = default_limit
	if _room_view_config_apply_button:
		_room_view_config_apply_button.disabled = true
	if _room_view_config_hint:
		_room_view_config_hint.text = "只有房主可以修改设置。"
	_room_config_dirty = false

func _is_current_user_host(detail: Dictionary) -> bool:
	return int(detail.get("host_id", -1)) == _user_id

func _get_current_player_entry(detail: Dictionary) -> Dictionary:
	var players: Variant = detail.get("players", [])
	if typeof(players) != TYPE_ARRAY:
		return {}
	for entry in players:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if int(entry.get("user_id", -1)) == _user_id:
			return entry
	return {}

func _format_room_player_entry(entry: Dictionary) -> String:
	var name := str(entry.get("username", "玩家"))
	var user_id := int(entry.get("user_id", -1))
	var tags: Array[String] = []
	if user_id == _user_id:
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

func _update_room_view(detail: Dictionary) -> void:
	if _room_view_container == null:
		return
	if detail.is_empty():
		_reset_room_view_controls()
		return
	var room_id := int(detail.get("id", -1))
	var room_label := _format_room_label(room_id)
	var state: String = LobbyUtils.format_room_state(str(detail.get("state", "")))
	var players: Array = detail.get("players", [])
	var limit := players.size()
	var config: Variant = detail.get("config", null)
	if typeof(config) == TYPE_DICTIONARY:
		limit = int(config.get("player_limit", limit))
	else:
		limit = int(detail.get("player_limit", limit))
	_current_room_config_limit = limit
	if _room_view_title_label:
		_room_view_title_label.text = room_label
	if _room_view_state_label:
		_room_view_state_label.text = "状态：%s    玩家：%d/%d" % [state, players.size(), limit]
	if _room_view_players_list:
		_room_view_players_list.clear()
		for entry in players:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			_room_view_players_list.add_item(_format_room_player_entry(entry))
	var current_player := _get_current_player_entry(detail)
	var current_state := str(current_player.get("state", "not_prepared"))
	var room_state := str(detail.get("state", "waiting"))
	var ready_text := "取消准备" if current_state == "prepared" else "准备"
	var can_ready := !_mock_mode and room_state == "waiting" and !_room_ready_inflight and !current_player.is_empty()
	if _room_view_ready_button:
		_room_view_ready_button.text = ready_text
		_room_view_ready_button.disabled = !can_ready
	if _room_view_leave_button:
		_room_view_leave_button.disabled = _room_leave_inflight or _mock_mode
	var is_host := _is_current_user_host(detail)
	var can_edit_config := is_host and !_mock_mode and !_room_config_inflight and room_state == "waiting"
	if _room_view_config_limit:
		_suppress_config_signal = true
		_room_view_config_limit.value = limit
		_suppress_config_signal = false
		_room_view_config_limit.editable = can_edit_config
		_room_config_dirty = false
	if _room_view_config_apply_button:
		var can_apply := can_edit_config and _room_config_dirty
		_room_view_config_apply_button.disabled = !can_apply
	if _room_view_config_hint:
		_room_view_config_hint.text = "你是房主，可以调整设置。" if is_host else "只有房主可以修改设置。"

func _set_room_view_status(message: String, is_error: bool) -> void:
	if _room_view_status_label == null:
		return
	var color := Color(0.95, 0.54, 0.54) if is_error else Color(1, 1, 1)
	_room_view_status_label.modulate = color
	_room_view_status_label.text = message

func _in_room_view() -> bool:
	return _room_view_container != null and _room_view_container.visible


func _set_lobby_status(message: String, is_error: bool) -> void:
	if _lobby_status_label == null:
		return
	var color := Color(0.95, 0.54, 0.54) if is_error else Color(1, 1, 1)
	_lobby_status_label.modulate = color
	_lobby_status_label.text = message

func _show_login_view() -> void:
	if _login_container:
		_login_container.visible = true
	if _lobby_container:
		_lobby_container.visible = false
	if _room_view_container:
		_room_view_container.visible = false
	if _generate_nickname_button:
		_generate_nickname_button.disabled = false
	if _nickname_input:
		_nickname_input.editable = true
		_nickname_input.select_all()
		_nickname_input.grab_focus()

func _show_lobby_view() -> void:
	if _login_container:
		_login_container.visible = false
	if _lobby_container:
		_lobby_container.visible = true
	if _room_view_container:
		_room_view_container.visible = false
	_render_room_summary(null)

func _show_error(message: String) -> void:
	if _error_dialog:
		_error_dialog.dialog_text = message
		_error_dialog.popup_centered()
	else:
		push_warning(message)

func _join_room_button_disabled(disabled: bool) -> void:
	if _join_room_button:
		_join_room_button.disabled = disabled

func _start_background_animation() -> void:
	_animation_time = 0.0

func _animate_poker_chips(delta: float) -> void:
	_animation_time += delta
	for i in range(_poker_chips.size()):
		var chip = _poker_chips[i]
		if chip:
			var offset = sin(_animation_time * 0.5 + i * 2.0) * 5.0
			chip.position.y += offset * delta
			chip.rotation += delta * 0.1 * (1 if i % 2 == 0 else -1)
