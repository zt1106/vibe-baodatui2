# Vibe Development Guide

This guide walks through the non-AI parts of the project: how the repository is laid out, the tooling you need, and the day-to-day commands for running and testing both the Zig backend and the Godot frontend.

## Project Overview

- `backend/` – Zig 0.15.x WebSocket server that powers the lobby/game protocol (`src/` holds the code, `build.zig` the build graph).
- `frontend/` – Godot 4.5 project for the client UI, mock lobby flows, and demo scenes (tests live under `test/`).
- `ai/` – Experimental AI helpers (not covered here).
- Supporting docs – `backend/README.md`, `backend/AGENT.md`, and `frontend/README.md` expand on component-specific details; `thinking.md` captures design notes.

## Environment Setup

### Backend (Zig)

1. Install Zig **0.15.2** or newer.
   - macOS: `brew install zig`.
   - Windows/Linux: download the matching archive from [ziglang.org/download](https://ziglang.org/download/) and put the extracted `zig` binary on your `PATH`.
2. Verify the toolchain: `zig version` (should print `0.15.x`).
3. From `backend/`, fetch third-party dependencies once: `zig build --fetch`.

> Tip: if you manage multiple Zig versions, consider `asdf`, `mise`, or `zigup` so you can switch per project.

### Frontend (Godot)

1. Install [Godot Engine 4.5](https://godotengine.org/download). The standard desktop build is sufficient; export templates are optional until packaging.
2. Launch Godot, choose **Import**, and point to `frontend/project.godot` to register the project with the editor.
3. Enable the GUT plugin if prompted (already configured in `project.godot`, but double-check in **Project → Project Settings → Plugins**).
4. Optional CLI use: place the `godot` executable on your `PATH` so you can run tests headlessly.

## Running the Backend Server

From the repository root:

```bash
cd backend
zig build run
```

- The server listens on `ws://0.0.0.0:7998` by default (`Config` lives in `backend/src/game_server.zig`).
- Log output is written to stderr with color-coded prefixes, e.g. `[info] starting websocket server...`.
- To persist logs while keeping live output, pipe stderr/stdout through `tee`:

  ```bash
  zig build run 2>&1 | tee ../backend.log
  ```

- Stop the server with `Ctrl+C`. The process also exits automatically if the Zig thread loop terminates because of an unrecoverable error.

## Frontend Workflow

- Launch the project: open `frontend/project.godot` in Godot and press `F5`. The client tries to connect to `ws://127.0.0.1:7998/`; adjust the endpoint by selecting the root node in `home_page.tscn` and editing the `websocket_url` export, or editing the default in `scripts/home_page_controller.gd`.
- Offline UI previews: from the login screen click **预览大厅（离线）** to populate the lobby with mock data if the backend is down.
- Running individual scenes:
  - `home_page.tscn` – main lobby/login flow. Select it and press `F6` (Run Current Scene) for quicker iteration than `F5`.
  - `example_card_demo/card_demo.tscn` – interactive card manipulation playground.
  - `two_row_hand_demo.tscn` – layout test for stacked hands.
  - `main.tscn` – project entry scene that simply loads the home page; useful when testing cold boot behaviour.
- Scene-specific scripts cache node paths; when renaming nodes or reorganising the tree, update `_cache_ui_nodes()` helpers in `scripts/` to avoid runtime errors.

Command-line scene launch (helpful for CI or quick checks):

```bash
godot --path frontend --scene res://home_page.tscn
```

## Testing

- **Backend unit (and integration) tests**  
  ```bash
  cd backend
  zig build test
  ```  
  This builds dedicated runners and spins up ephemeral WebSocket servers. Ensure ports `7998`, `21001-21002`, and `22001-22021` are free. For deeper coverage of the integration harness, see `backend/AGENT.md`.

- **Frontend GUT tests**  
  Run them headlessly from the repository root:
  ```bash
  godot --headless --path frontend --script addons/gut/gut_cmdln.gd -gdir=res://test
  ```  
  In the editor, open **Project → Tools → GUT** (or the **Test** dock) and run suites interactively.

## Working With Logs

- Backend logs appear directly in the terminal. Errors are red, warnings yellow, info cyan, debug grey (`backend/src/log.zig`). Use `--verbose` when launching Godot to surface frontend warnings: `godot --verbose --path frontend`.
- Godot editor logs are visible in the **Output** panel; when running headless, messages go to stdout/stderr. Redirect to a file with `godot --headless ... > frontend.log 2>&1`.

## Additional References

- `backend/README.md` – architecture deep dive, message protocol, and module reference.
- `backend/AGENT.md` – curated notes on build/test conventions and integration test locations.
- `frontend/README.md` – scene structure, mock data workflows, and additional Godot tips.

With these steps covered you can bring up the stack, iterate on gameplay flows, and keep both layers under test without diving into the AI prototypes.
