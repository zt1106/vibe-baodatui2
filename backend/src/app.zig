const std = @import("std");
const ws = @import("websocket");

const messages = @import("messages.zig");
const users = @import("user_service.zig");
const rooms = @import("room_service.zig");

const log = std.log.scoped(.game_app);

pub const ConnectionState = struct {
    player_name: ?[]u8 = null,
    user_name: ?[]u8 = null,
    user_id: ?i64 = null,
    room_id: ?u32 = null,
    disconnected: bool = false,
};

const Player = struct {
    score: u32 = 0,
};

const HandlerFn = *const fn (*GameApp, *ws.Conn, *ConnectionState, *messages.Message) anyerror!void;

pub const RegisterHandlerError = error{HandlerExists} || std.mem.Allocator.Error;

pub const GameApp = struct {
    allocator: std.mem.Allocator,
    players: std.StringHashMap(Player),
    handlers: std.StringHashMap(HandlerFn),
    mutex: std.Thread.Mutex = .{},
    user_service: users.Service,
    room_service: rooms.RoomService,

    pub fn init(allocator: std.mem.Allocator) !GameApp {
        var self = GameApp{
            .allocator = allocator,
            .players = std.StringHashMap(Player).init(allocator),
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
            .user_service = users.Service.init(allocator),
            .room_service = rooms.RoomService.init(allocator),
        };
        errdefer self.deinit();

        try self.ensureSchema();
        try self.registerRequestHandlerTyped(
            messages.UserRegisterPayload,
            messages.UserResponsePayload,
            "user_register",
            handleUserRegister,
        );
        try self.registerRequestHandlerTyped(
            messages.UserLoginPayload,
            messages.UserResponsePayload,
            "user_login",
            handleUserLogin,
        );
        try self.registerRequestHandlerTyped(
            messages.UserGetPayload,
            messages.UserResponsePayload,
            "user_get",
            handleUserGet,
        );
        try self.registerRequestHandlerTyped(
            messages.UserUpdatePayload,
            messages.UserResponsePayload,
            "user_update",
            handleUserUpdate,
        );
        try self.registerRequestHandlerTyped(
            messages.UserDeletePayload,
            messages.UserDeleteResponsePayload,
            "user_delete",
            handleUserDelete,
        );
        try self.registerRequestHandlerTyped(
            messages.PingPayload,
            messages.SystemPayload,
            "ping",
            handlePing,
        );
        try self.registerHandler("room_list", handleRoomList);
        try self.registerRequestHandlerTyped(
            messages.RoomCreatePayload,
            messages.RoomDetailPayload,
            "room_create",
            handleRoomCreate,
        );
        try self.registerRequestHandlerTyped(
            messages.RoomJoinPayload,
            messages.RoomDetailPayload,
            "room_join",
            handleRoomJoin,
        );
        try self.registerRequestHandlerTyped(
            messages.RoomLeavePayload,
            messages.RoomLeaveResponsePayload,
            "room_leave",
            handleRoomLeave,
        );
        try self.registerRequestHandlerTyped(
            messages.RoomReadyPayload,
            messages.RoomDetailPayload,
            "room_ready",
            handleRoomReady,
        );
        try self.registerRequestHandlerTyped(
            messages.RoomStartPayload,
            messages.RoomDetailPayload,
            "room_start",
            handleRoomStart,
        );

        return self;
    }

    pub fn deinit(self: *GameApp) void {
        self.room_service.deinit();
        self.user_service.deinit();

        var it = self.players.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            self.allocator.free(@constCast(name));
        }
        self.players.deinit();

        var hit = self.handlers.iterator();
        while (hit.next()) |entry| {
            const name = entry.key_ptr.*;
            self.allocator.free(@constCast(name));
        }
        self.handlers.deinit();
    }

    pub fn onConnect(self: *GameApp, conn: *ws.Conn, state: *ConnectionState) !void {
        _ = state;
        log.info("connection established", .{});
        try self.sendMessage(conn, "system", .{
            .code = "connected",
            .message = "Welcome to the game server",
        });
    }

    pub fn onMessage(
        self: *GameApp,
        conn: *ws.Conn,
        state: *ConnectionState,
        message: *messages.Message,
    ) !void {
        const type_name = message.typeName();

        self.mutex.lock();
        const handler = self.handlers.get(type_name);
        self.mutex.unlock();

        if (handler) |func| {
            try func(self, conn, state, message);
            return;
        }

        log.warn("unknown message type: {s}", .{type_name});
        try self.sendMessage(conn, "system", .{
            .code = "unknown_type",
            .message = "Unrecognized message type",
        });
    }

    pub fn onDisconnect(self: *GameApp, state: *ConnectionState) void {
        if (state.disconnected) {
            return;
        }
        state.disconnected = true;

        if (state.player_name) |name| {
            const key: []const u8 = name;
            self.mutex.lock();
            const removed = self.players.remove(key);
            self.mutex.unlock();

            if (removed) {
                log.info("player disconnected: {s}", .{key});
            } else {
                log.info("connection disconnected without registered player", .{});
            }

            self.allocator.free(name);
            state.player_name = null;
        } else {
            log.info("connection closed before join", .{});
        }

        if (state.user_name) |user| {
            self.allocator.free(user);
            state.user_name = null;
        }
        const user_id = state.user_id;
        state.user_id = null;
        state.room_id = null;

        if (user_id) |uid| {
            self.room_service.handleDisconnect(uid);
        }
    }

    pub fn registerHandler(self: *GameApp, name: []const u8, handler: HandlerFn) RegisterHandlerError!void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.handlers.contains(name)) {
            return error.HandlerExists;
        }

        try self.handlers.put(name_copy, handler);
    }

    pub fn registerHandlerTyped(
        self: *GameApp,
        comptime Payload: type,
        name: []const u8,
        handler: fn (*GameApp, *ws.Conn, *ConnectionState, Payload) anyerror!void,
    ) RegisterHandlerError!void {
        const thunk = struct {
            fn call(
                app: *GameApp,
                conn: *ws.Conn,
                state: *ConnectionState,
                message: *messages.Message,
            ) anyerror!void {
                const payload = try message.payloadAs(Payload);
                try handler(app, conn, state, payload);
            }
        };

        try self.registerHandler(name, thunk.call);
    }

    pub fn registerRequestHandlerTyped(
        self: *GameApp,
        comptime RequestPayload: type,
        comptime ResponsePayload: type,
        name: []const u8,
        handler: fn (*GameApp, *ws.Conn, *ConnectionState, RequestPayload) anyerror!ResponsePayload,
    ) RegisterHandlerError!void {
        const ResponseMessage = messages.ResponseEnvelope(ResponsePayload);

        const thunk = struct {
            fn call(
                app: *GameApp,
                conn: *ws.Conn,
                state: *ConnectionState,
                message: *messages.Message,
            ) anyerror!void {
                const payload = try message.payloadAs(RequestPayload);
                const request_type = message.typeName();

                if (ResponsePayload == void) {
                    try handler(app, conn, state, payload);
                    try app.sendMessage(conn, "response", ResponseMessage{
                        .request = request_type,
                    });
                    return;
                }

                const response = try handler(app, conn, state, payload);
                try app.sendMessage(conn, "response", ResponseMessage{
                    .request = request_type,
                    .data = response,
                });
            }
        };

        try self.registerHandler(name, thunk.call);
    }

    fn handleUserRegister(
        self: *GameApp,
        _: *ws.Conn,
        state: *ConnectionState,
        payload: messages.UserRegisterPayload,
    ) !messages.UserResponsePayload {
        return self.user_service.handleRegister(state, payload);
    }

    fn handleUserLogin(
        self: *GameApp,
        _: *ws.Conn,
        state: *ConnectionState,
        payload: messages.UserLoginPayload,
    ) !messages.UserResponsePayload {
        return self.user_service.handleLogin(state, payload);
    }

    fn handleUserGet(
        self: *GameApp,
        _: *ws.Conn,
        _: *ConnectionState,
        payload: messages.UserGetPayload,
    ) !messages.UserResponsePayload {
        return self.user_service.handleGet(payload);
    }

    fn handleUserUpdate(
        self: *GameApp,
        _: *ws.Conn,
        state: *ConnectionState,
        payload: messages.UserUpdatePayload,
    ) !messages.UserResponsePayload {
        return self.user_service.handleUpdate(state, payload);
    }

    fn handleUserDelete(
        self: *GameApp,
        _: *ws.Conn,
        state: *ConnectionState,
        payload: messages.UserDeletePayload,
    ) !messages.UserDeleteResponsePayload {
        return self.user_service.handleDelete(state, payload);
    }

    fn handlePing(
        self: *GameApp,
        _: *ws.Conn,
        _: *ConnectionState,
        _: messages.PingPayload,
    ) !messages.SystemPayload {
        _ = self;
        return .{
            .code = "pong",
            .message = "Heartbeat ok",
        };
    }

    fn sendMessage(
        self: *GameApp,
        conn: *ws.Conn,
        type_name: []const u8,
        payload: anytype,
    ) !void {
        const frame = try messages.encodeMessage(self.allocator, type_name, payload);
        defer self.allocator.free(frame);
        try conn.write(frame);
    }

    fn ensureSchema(self: *GameApp) !void {
        self.user_service.ensureSchema();
        self.room_service.ensureSchema();
    }
};

fn handleRoomList(
    self: *GameApp,
    conn: *ws.Conn,
    _: *ConnectionState,
    message: *messages.Message,
) anyerror!void {
    _ = try message.payloadAs(messages.RoomListRequestPayload);
    var view = try self.room_service.listRooms(self.allocator);
    defer view.deinit();
    const ResponseMessage = messages.ResponseEnvelope(messages.RoomListResponsePayload);
    const response = ResponseMessage{
        .request = message.typeName(),
        .data = view.payload,
    };
    try self.sendMessage(conn, "response", response);
}

fn handleRoomCreate(
    self: *GameApp,
    _: *ws.Conn,
    state: *ConnectionState,
    payload: messages.RoomCreatePayload,
) anyerror!messages.RoomDetailPayload {
    const detail = try self.room_service.createRoom(state.user_id, state.user_name, payload);
    state.room_id = detail.id;
    return detail;
}

fn handleRoomJoin(
    self: *GameApp,
    _: *ws.Conn,
    state: *ConnectionState,
    payload: messages.RoomJoinPayload,
) anyerror!messages.RoomDetailPayload {
    const detail = try self.room_service.joinRoom(state.user_id, state.user_name, payload);
    state.room_id = detail.id;
    return detail;
}

fn handleRoomLeave(
    self: *GameApp,
    _: *ws.Conn,
    state: *ConnectionState,
    _: messages.RoomLeavePayload,
) anyerror!messages.RoomLeaveResponsePayload {
    const result = try self.room_service.leaveRoom(state.user_id);
    state.room_id = null;
    return result;
}

fn handleRoomReady(
    self: *GameApp,
    _: *ws.Conn,
    state: *ConnectionState,
    payload: messages.RoomReadyPayload,
) anyerror!messages.RoomDetailPayload {
    const detail = try self.room_service.setPrepared(state.user_id, payload);
    state.room_id = detail.id;
    return detail;
}

fn handleRoomStart(
    self: *GameApp,
    _: *ws.Conn,
    state: *ConnectionState,
    _: messages.RoomStartPayload,
) anyerror!messages.RoomDetailPayload {
    const detail = try self.room_service.startGame(state.user_id);
    state.room_id = detail.id;
    return detail;
}
