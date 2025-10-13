# Vibe Game Server Backend

This directory contains the Zig-based WebSocket backend that powers the real-time features of the Vibe project. It exposes a lightweight game lobby and matchmaking flow built entirely with in-memory services, making it fast to iterate on gameplay or protocol changes.

## Highlights
- WebSocket server with configurable runtime built on [`websocket.zig`](https://github.com/karlseguin/websocket.zig)
- In-memory user registry and room management with thread-safe coordination
- Structured message envelope and typed request/response handlers
- Extensive unit and integration tests that exercise the full handshake and message flow

## Requirements
- Zig `0.15.1` or newer (matches `build.zig.zon` minimum)
- A POSIX-like environment (tests spin up local TCP sockets)
- Network ports `7998`, `21001-21002`, and `22001-22021` available during development tests

> **Tip:** Fetch dependencies before the first build: `zig build --fetch`.

## Quick Start
1. Install the required Zig toolchain.
2. From `backend/`, run the server in debug mode:
   ```bash
   zig build run
   ```
   The server listens on `ws://0.0.0.0:7998` by default.
3. Build an optimized binary (optional):
   ```bash
   zig build -Doptimize=ReleaseSafe
   ```
   Artifacts land under `zig-out/bin/backend`.

### Running Tests
- All tests (unit + integration):
  ```bash
  zig build test
  ```
  This command compiles two test runners: one for the reusable library module and one for the executable entry point. Integration tests launch ephemeral WebSocket servers, so ensure the ports noted above are free.

## Project Layout
- `src/main.zig` – executable entry point; boots the app, installs custom logging, and runs the WebSocket server.
- `src/app.zig` – central game application. Registers message handlers, coordinates user and room services, and manages per-connection state.
- `src/game_server.zig` – WebSocket server wrapper (`websocket.Server`) with runtime configuration, start/stop helpers, and integration tests.
- `src/messages.zig` – shared protocol definitions, JSON encoding/decoding helpers, and message envelope utilities.
- `src/user_service.zig` – in-memory user management (register/login/update/delete) with validation logic.
- `src/room_service.zig` – room lifecycle, readiness, and lobby coordination with thread-safe data structures.
- `src/ws_test_client.zig` – lightweight WebSocket client used by integration tests to exercise the live protocol.
- `src/root.zig` – root module that re-exports public symbols and wires test coverage.
- `build.zig` / `build.zig.zon` – Zig build configuration and dependency lockfile.

## Runtime Behavior
- On startup the server allocates a thread-safe General Purpose Allocator (GPA), initializes the `GameApp`, and binds a WebSocket listener according to `game_server.Config` (defaults: `0.0.0.0:7998`, 5s handshake timeout, 1 KiB frames).
- Each client connection receives a welcome system message:  
  ```json
  {"type":"system","data":{"code":"connected","message":"Welcome to the game server"}}
  ```
- Incoming frames are parsed as JSON envelopes. Handler dispatch is guarded by a mutex to ensure thread-safe access to shared maps.
- On disconnect, the service cleans up user/room membership and releases any heap-allocated names associated with the connection.

## Message Protocol
All application frames share the same top-level envelope:
```json
{
  "type": "message_type",
  "data": { ... }   // optional; defaults to null when omitted
}
```

### Responses
Request/response pairs return a `type` of `response` with the original request name embedded:
```json
{
  "type": "response",
  "data": {
    "request": "room_join",
    "data": { ... }  // optional if the handler returns `void`
  }
}
```
Handlers that produce no payload still emit the envelope with only the `request` field.

### System Messages
- `connected` – JSON-RPC notification with method `system` and payload `{ "code": "connected", "message": "Welcome to the game server" }`.
- `method not found` – JSON-RPC error `-32601` returned when a client calls an unknown method.
- `invalid params` – JSON-RPC error `-32602` if a request payload fails validation.
- `handler error` – JSON-RPC error `-32000` with the Zig error tag in the `message` field (e.g. `NotLoggedIn`, `RoomFull`, `UserExists`).

## User Management Messages
| Method | Request params | Response (JSON-RPC result) | Notes |
| --- | --- | --- | --- |
| `user_set_name` | `{ "nickname": "Alice" }` | `{ "id": number, "username": "Alice" }` | Trims whitespace, enforces uniqueness, and either assigns or renames the caller’s guest identity. |

Validation errors surface via JSON-RPC error codes with messages such as `InvalidUsername` or `UserExists`.

## Room Management Messages
| Method | Request params | Response (JSON-RPC result) | Notes |
| --- | --- | --- | --- |
| `room_list` | `{}` | `data: { "rooms": [...] }` | Returns snapshots of all rooms (id, name, state, occupancy). |
| `room_create` | `{ "name": "Lobby 1", "player_limit": 4 }` | `data: RoomDetailPayload` | Host-only creation; enforces unique name and minimum limit (`>= 2`). |
| `room_join` | `{ "room_id": 3 }` | `data: RoomDetailPayload` | Adds the caller if slots are free and the room is not `in_game`. |
| `room_leave` | `{}` | `data: { "room_id": 3 }` | Removes the caller; empty rooms are deleted automatically. |
| `room_ready` | `{ "prepared": true }` | `data: RoomDetailPayload` | Marks the caller’s readiness status. |
| `room_start` | `{}` | `data: RoomDetailPayload` | Host-only; transitions the room to `in_game` once all players are prepared. |

Potential error codes include `NotLoggedIn`, `MissingUsername`, `AlreadyInRoom`, `RoomNameExists`, `RoomNotFound`, `RoomFull`, `RoomInProgress`, `NotInRoom`, `NotHost`, and `PlayersNotReady`.

## Utility Messages
| Method | Request params | Response | Notes |
| --- | --- | --- | --- |
| `ping` | `{}` | JSON-RPC result `{ "code": "pong", "message": "Heartbeat ok" }` | Simple health check to keep connections alive. |

## Testing Support
- `ws_test_client.zig` provides a synchronous WebSocket test client that can send protocol messages, await typed responses, and validate payloads. Integration helpers (`withReadyClient`) spin up a fully wired server in a temp directory, ensuring filesystem isolation for tests that depend on the current working directory.
- Both `user_service` and `room_service` include direct unit tests plus end-to-end scenarios that validate the live WebSocket flow (registration, joining rooms, readiness, etc.).

## Extending the Server
- Register new handlers in `GameApp.init` using `registerHandler` (fire-and-forget) or `registerRequestHandlerTyped` (structured responses).
- To expose the server as a library, import the `backend` module (`@import("backend")`) and reuse `game_server.start` with a custom `GameApp` implementation.
- Adjust networking defaults by updating the `Config` passed to `game_server.run` in `src/main.zig`.
- Persistence layers can replace the in-memory services by implementing the same function signatures and swapping them in within `GameApp`.

With these building blocks, you can iterate on gameplay logic, extend the protocol, or integrate the backend with other subsystems while keeping the developer workflow intentionally simple.
