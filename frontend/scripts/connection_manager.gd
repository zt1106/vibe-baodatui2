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
			_client.close()
			emit_signal("connection_failed")
	
	# Always poll the WebSocket to update its state
	_client.poll()
	
	# Check connection state after polling
	var state = _client.get_ready_state()
	match state:
		WebSocketPeer.STATE_CONNECTING:
			# Still connecting, do nothing
			pass
		WebSocketPeer.STATE_OPEN:
			if _connecting:
				_on_handshake_completed()
		WebSocketPeer.STATE_CLOSING:
			# Connection is closing
			pass
		WebSocketPeer.STATE_CLOSED:
			if _connecting:
				_on_connection_error()
			elif _connected:
				_on_connection_closed()

func _attempt_connection() -> void:
	_elapsed = 0.0
	_connecting = true
	var err = _client.connect_to_url(websocket_url)
	if err != OK:
		_connecting = false
		emit_signal("connection_failed")
		return

func _on_handshake_completed() -> void:
	_connecting = false
	_connected = true
	emit_signal("connection_succeeded")

func _on_connection_closed() -> void:
	_connected = false
	# Connection was closed, could implement reconnection logic here

func _on_connection_error() -> void:
	_connecting = false
	_connected = false
	emit_signal("connection_failed")

func _on_connection_failed() -> void:
	if _error_dialog:
		_error_dialog.popup_centered()
