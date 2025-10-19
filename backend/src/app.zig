const std = @import("std");
const ws = @import("websocket");

const messages = @import("messages.zig");
const users = @import("user_service.zig");
const rooms = @import("room_service.zig");

const log = std.log.scoped(.game_app);

pub const ConnectionState = struct {
    user_name: ?[]u8 = null,
    user_id: ?i64 = null,
    room_id: ?u32 = null,
    disconnected: bool = false,
};

const HandlerFn = *const fn (*GameApp, *ws.Conn, *ConnectionState, *messages.Call) anyerror!void;

pub const RegisterHandlerError = error{HandlerExists} || std.mem.Allocator.Error;

pub const GameApp = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(HandlerFn),
    mutex: std.Thread.Mutex = .{},
    user_service: users.UserService,
    room_service: rooms.RoomService,

    pub fn init(allocator: std.mem.Allocator) !GameApp {
        var self = GameApp{
            .allocator = allocator,
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
            .user_service = users.UserService.init(allocator),
            .room_service = rooms.RoomService.init(allocator),
        };
        errdefer self.deinit();

        try self.registerRequestHandlerTyped(
            messages.UserSetNamePayload,
            messages.UserInfoPayload,
            "user_set_name",
            handleUserSetName,
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
        try self.sendNotification(conn, "system", .{
            .code = "connected",
            .message = "Welcome to the game server",
        });
    }

    pub fn onCall(
        self: *GameApp,
        conn: *ws.Conn,
        state: *ConnectionState,
        call: *messages.Call,
    ) !void {
        const method_name = call.methodName();

        self.mutex.lock();
        const handler = self.handlers.get(method_name);
        self.mutex.unlock();

        if (handler) |func| {
            func(self, conn, state, call) catch |err| {
                log.err("handler error: {}", .{err});
                if (call.idValue()) |id| {
                    try self.sendError(conn, id, messages.RpcErrorCodes.ServerError, @errorName(err));
                }
            };
            return;
        }

        log.warn("unknown method: {s}", .{method_name});
        if (call.idValue()) |id| {
            try self.sendError(conn, id, messages.RpcErrorCodes.MethodNotFound, "Method not found");
        }
    }

    pub fn onDisconnect(self: *GameApp, state: *ConnectionState) void {
        if (state.disconnected) {
            return;
        }
        state.disconnected = true;

        if (state.user_name) |user| {
            log.info("user disconnected: {s}", .{user});
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
            const func = handler;
            fn call(
                app: *GameApp,
                conn: *ws.Conn,
                state: *ConnectionState,
                rpc_call: *messages.Call,
            ) anyerror!void {
                const payload = app.parseOrReject(conn, rpc_call, Payload) orelse return;
                try func(app, conn, state, payload);
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
        const thunk = struct {
            const func = handler;
            fn call(
                app: *GameApp,
                conn: *ws.Conn,
                state: *ConnectionState,
                rpc_call: *messages.Call,
            ) anyerror!void {
                const payload = app.parseOrReject(conn, rpc_call, RequestPayload) orelse return;

                if (@typeInfo(ResponsePayload) == .void) {
                    try func(app, conn, state, payload);
                    if (rpc_call.idValue()) |id| {
                        try app.sendResponseNull(conn, id);
                    }
                    return;
                }

                const response = try func(app, conn, state, payload);
                if (rpc_call.idValue()) |id| {
                    try app.sendResponse(conn, id, response);
                }
            }
        };

        try self.registerHandler(name, thunk.call);
    }

    fn parseOrReject(
        self: *GameApp,
        conn: *ws.Conn,
        call: *messages.Call,
        comptime Payload: type,
    ) ?Payload {
        return call.paramsAs(Payload) catch |err| {
            if (call.idValue()) |id| {
                self.sendError(conn, id, messages.RpcErrorCodes.InvalidParams, "Invalid params") catch |write_err| {
                    log.err("failed to send invalid params response: {}", .{write_err});
                };
            } else {
                log.warn("invalid params for notification method {s}: {}", .{ call.methodName(), err });
            }
            return null;
        };
    }

    fn handleUserSetName(
        self: *GameApp,
        _: *ws.Conn,
        state: *ConnectionState,
        payload: messages.UserSetNamePayload,
    ) !messages.UserInfoPayload {
        return self.user_service.handleSetName(state, payload);
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

    fn logOutbound(self: *GameApp, frame: []const u8) void {
        const pretty = messages.formatPrettyJson(self.allocator, frame) catch |err| {
            log.info("WebSocket -> (raw, {s}): {s}", .{ @errorName(err), frame });
            return;
        };
        defer self.allocator.free(pretty);
        log.info("WebSocket ->\n{s}", .{pretty});
    }

    fn sendNotification(
        self: *GameApp,
        conn: *ws.Conn,
        method: []const u8,
        params: anytype,
    ) !void {
        const frame = try messages.encodeNotification(self.allocator, method, params);
        defer self.allocator.free(frame);
        self.logOutbound(frame);
        try conn.write(frame);
    }

    fn sendResponse(
        self: *GameApp,
        conn: *ws.Conn,
        id: messages.Id,
        result: anytype,
    ) !void {
        const frame = try messages.encodeResponse(self.allocator, id, result);
        defer self.allocator.free(frame);
        self.logOutbound(frame);
        try conn.write(frame);
    }

    fn sendResponseNull(
        self: *GameApp,
        conn: *ws.Conn,
        id: messages.Id,
    ) !void {
        const frame = try messages.encodeResponseNull(self.allocator, id);
        defer self.allocator.free(frame);
        self.logOutbound(frame);
        try conn.write(frame);
    }

    fn sendError(
        self: *GameApp,
        conn: *ws.Conn,
        id: ?messages.Id,
        code: i64,
        message: []const u8,
    ) !void {
        const frame = try messages.encodeError(self.allocator, id, code, message);
        defer self.allocator.free(frame);
        self.logOutbound(frame);
        try conn.write(frame);
    }
};

fn handleRoomList(
    self: *GameApp,
    conn: *ws.Conn,
    _: *ConnectionState,
    call: *messages.Call,
) anyerror!void {
    _ = self.parseOrReject(conn, call, messages.RoomListRequestPayload) orelse return;
    var view = try self.room_service.listRooms(self.allocator);
    defer view.deinit();
    if (call.idValue()) |id| {
        try self.sendResponse(conn, id, view.payload);
    }
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
