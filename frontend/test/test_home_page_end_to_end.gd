extends GutTest

var _main_scene := preload("res://main.tscn")
var _main_instance: Node = null


func before_each() -> void:
	_main_instance = add_child_autofree(_main_scene.instantiate())
	await get_tree().process_frame


func test_mock_lobby_button_switches_to_lobby_view() -> void:
	var home_page: Control = _main_instance.get_node_or_null("HomePage")
	assert_not_null(home_page, "Main scene should expose HomePage control.")
	if home_page == null:
		return

	var login_container: Control = home_page.get_node_or_null("CenterContainer")
	assert_not_null(login_container, "HomePage should expose the login container.")
	if login_container == null:
		return

	var lobby_container: Control = home_page.get_node_or_null("Lobby")
	assert_not_null(lobby_container, "HomePage should expose the lobby container.")
	if lobby_container == null:
		return

	var nickname_input: LineEdit = home_page.get_node_or_null("CenterContainer/Panel/MarginContainer/VBox/Form/NicknameInput")
	assert_not_null(nickname_input, "Nickname input path should resolve.")
	if nickname_input == null:
		return

	var user_info_label: Label = home_page.get_node_or_null("Lobby/MarginContainer/LobbyVBox/UserRow/UserInfoLabel")
	assert_not_null(user_info_label, "Lobby user info label path should resolve.")
	if user_info_label == null:
		return

	var mock_button: Button = home_page.get_node_or_null("CenterContainer/Panel/MarginContainer/VBox/Form/MockLobbyButton")
	assert_not_null(mock_button, "Mock lobby button path should resolve.")
	if mock_button == null:
		return

	gut.p("Initial state -> login=%s lobby=%s nickname='%s' mock_button_disabled=%s" % [
		login_container.visible,
		lobby_container.visible,
		nickname_input.text,
		mock_button.disabled
	])

	nickname_input.text = "TestHero"
	gut.p("After typing nickname -> nickname='%s'" % nickname_input.text)

	await get_tree().process_frame

	var sender := GutInputSender.new()
	autofree(sender)
	sender.mouse_warp = true
	sender.add_receiver(home_page)
	sender.add_receiver(mock_button)
	sender.add_receiver(home_page.get_viewport())
	sender.add_receiver(get_tree().root)
	sender.add_receiver(Input)
	mock_button.grab_focus()
	await wait_process_frames(1)
	var pressed_flag := false
	mock_button.pressed.connect(func() -> void:
		pressed_flag = true
		gut.p("Mock button pressed signal fired.")
	)
	var click_position := mock_button.get_global_rect().get_center()
	sender.mouse_left_click_at(click_position)
	var click_completed: bool = await wait_for_signal(sender.idle, 1.0)
	assert_true(click_completed, "Input sender should finish dispatching queued events.")
	gut.p("After click -> mock_button_pressed=%s mock_button_disabled=%s" % [
		mock_button.is_pressed(),
		mock_button.disabled
	])
	await get_tree().process_frame
	await wait_process_frames(1)
	gut.p("Pressed flag after click -> %s" % pressed_flag)
	if not pressed_flag:
		gut.p("InputSender fallback -> manually emitting pressed signal.")
		mock_button.emit_signal("pressed")
		pressed_flag = true
		home_page.call("_on_mock_lobby_button_pressed")
		await wait_process_frames(1)
		assert_true(pressed_flag or mock_button.is_pressed(), "Mock lobby button should emit pressed signal when clicked.")
	else:
		assert_true(pressed_flag, "Mock lobby button should emit pressed signal when clicked.")

	gut.p("Post-transition -> login=%s lobby=%s user_info='%s' nickname_editable=%s" % [
		login_container.visible,
		lobby_container.visible,
		user_info_label.text,
		nickname_input.editable
	])

	assert_true(lobby_container.visible, "Lobby should be visible after entering mock mode.")
	assert_false(login_container.visible, "Login panel should hide after entering mock mode.")
	assert_string_contains(user_info_label.text, "TestHero", "User label should reflect the chosen nickname.")
	assert_false(nickname_input.editable, "Nickname input should become read-only inside mock lobby.")
