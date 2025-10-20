# Baodatui Poker Game Frontend (Godot 4.5)

This is the Godot client for the Baodatui poker experience. It ships with a fully wired lobby UI, sample data for rapid prototyping, and the scaffolding required to integrate with the backend WebSocket service.

## Requirements

- [Godot Engine 4.5](https://godotengine.org/) (standard desktop release)

## Quick Start

1. Launch Godot 4.5.
2. In the Project Manager choose **Import**, point to `project.godot`, and pick a local project name.
3. Open the project, press <kbd>F5</kbd>, and the client will attempt to connect to the default backend (`ws://127.0.0.1:7998/`).
4. If the backend is offline, click **预览大厅（离线）** in the login screen to load the mock lobby content and validate the UI flows without a server.

## Project Structure

- `project.godot` – core Godot project metadata and editor settings.
- `main.tscn` – entry point that instantiates `home_page.tscn`.
- `home_page.tscn` – primary scene containing login, lobby, and room views.
- `scripts/` – gameplay logic (`home_page_controller.gd`, `room_view_controller.gd`, helpers, and mock data).
- `default_env.tres` – default environment for lighting/background.
- `抱大腿.png` – placeholder illustration referenced by the home page scene.

## Scene Flow & Controllers

- `main.tscn` loads `home_page.tscn`, which attaches `home_page_controller.gd` to drive startup, network calls, and state transitions.
- The controller connects to the backend via `WebSocketPeer`, manages reconnection attempts, and exposes exported properties (`websocket_url`, `timeout_seconds`) for easy tweaking in the Inspector.
- `room_view_controller.gd` owns the room details panel, button enablement, and localized labels, while `lobby_utils.gd` formats lobby/room strings.
- All user-facing strings in scenes and scripts default to Simplified Chinese; keep future additions consistent (see `AGENT.md`).

## Backend Integration

- The client expects a WebSocket backend that implements the lobby protocol on `ws://127.0.0.1:7998/`. Adjust the endpoint by selecting the root node in `home_page.tscn` and editing the `websocket_url` export, or by changing the default in `scripts/home_page_controller.gd`.
- Connection failures surface through the **连接错误** dialog with actionable guidance; use this to confirm the backend address while iterating.
- `home_page_controller.gd` tracks inflight requests (`_pending_requests`) so UI buttons remain responsive. When adding new RPCs, follow the same pattern to keep state transitions predictable.

## Mock Lobby & Sample Data

- The **预览大厅（离线）** button toggles `_mock_mode` and populates the UI using `scripts/mock_data.gd`. This is useful for designing layouts or testing copy without a running backend.
- Mock rooms include a variety of states (`waiting`, `in_game`) so you can verify formatting and iconography. Extend `MockData.build_mock_rooms()` if you need additional scenarios.
- Randomized nicknames come from `scripts/random_nickname.gd`; update its prefix/suffix lists to align with the tone of the product.

## Development Tips

- Keep reusable UI tweaks inside the `.tscn` files; scripts assume specific node paths cached in `_cache_ui_nodes()`, so rename nodes carefully or update the cache helper alongside layout changes.
- When adding new player-facing copy, confirm it renders in Simplified Chinese and fits existing layout constraints.
- Leverage Godot’s live scene reload (`Ctrl` + `Shift` + `F5`) to test UI edits quickly, and use the built-in WebSocket debugger to trace traffic between the client and backend.
- Before exporting builds, configure presets in **Project → Export**; the project currently inherits default Godot settings and does not ship platform-specific overrides.
