extends Node

@export var websocket_url: String = "ws://127.0.0.1:7998/"
@export var timeout_seconds: float = 3.0

var _client := WebSocketPeer.new()
var _connected: bool = false
var _elapsed: float = 0.0
var _connecting: bool = false

signal connection_succeeded
signal connection_failed

var _error_dialog: AcceptDialog = null

func _ready() -> void:
	_error_dialog = get_node_or_null("ErrorDialog") as AcceptDialog
	if _error_dialog:
		connection_failed.connect(_on_connection_failed)
	_attempt_connection()

func _process(delta: float) -> void:
	if _connecting:
		_elapsed += delta
		if _elapsed >= timeout_seconds:
			_connecting = false
			_client.disconnect_from_host(1000, "timeout")
			emit_signal("connection_failed")
	if _client.get_ready_state() == WebSocketPeer.STATE_CONNECTING or _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_client.poll()

func _attempt_connection() -> void:
	_elapsed = 0.0
	_connecting = true
	var err = _client.connect_to_url(websocket_url)
	if err != OK:
		_connecting = false
		emit_signal("connection_failed")
		return
	_client.handshake_completed.connect(_on_handshake_completed)
	_client.connection_closed.connect(_on_connection_closed)
	_client.connection_error.connect(_on_connection_error)

func _on_handshake_completed(_protocol: String = "") -> void:
	_connecting = false
	_connected = true
	emit_signal("connection_succeeded")

func _on_connection_closed(_was_clean: bool = false) -> void:
	if not _connected and _connecting:
		# closed before success (likely refused)
		_connecting = false
		emit_signal("connection_failed")

func _on_connection_error() -> void:
	if _connecting:
		_connecting = false
		emit_signal("connection_failed")

func _on_connection_failed() -> void:
	if _error_dialog:
		_error_dialog.popup_centered()
