const std = @import("std");
const ws = @import("websocket");

const messages = @import("messages.zig");

const log = std.log.scoped(.game_app);

pub const ConnectionState = struct {
    name: ?[]u8 = null,
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

    pub fn init(allocator: std.mem.Allocator) !GameApp {
        var self = GameApp{
            .allocator = allocator,
            .players = std.StringHashMap(Player).init(allocator),
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
        };
        errdefer self.deinit();

        try self.registerHandlerTyped(messages.JoinPayload, "join", handleJoin);
        try self.registerHandlerTyped(messages.ChatPayload, "chat", handleChat);
        try self.registerHandlerTyped(messages.MovePayload, "move", handleMove);
        try self.registerHandlerTyped(messages.PingPayload, "ping", handlePing);

        return self;
    }

    pub fn deinit(self: *GameApp) void {
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
        try self.sendSystem(conn, .{
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
        try self.sendSystem(conn, .{
            .code = "unknown_type",
            .message = "Unrecognized message type",
        });
    }

    pub fn onDisconnect(self: *GameApp, state: *ConnectionState) void {
        if (state.name) |name| {
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
            state.name = null;
        } else {
            log.info("connection closed before join", .{});
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

    fn handleJoin(
        self: *GameApp,
        conn: *ws.Conn,
        state: *ConnectionState,
        payload: messages.JoinPayload,
    ) !void {
        const name_slice = payload.name;
        var previous_name: ?[]u8 = null;

        const name_copy_raw = try self.allocator.dupe(u8, name_slice);
        const name_copy = name_copy_raw;
        var keep_name = false;
        defer if (!keep_name) self.allocator.free(name_copy);

        self.mutex.lock();
        if (self.players.contains(name_slice)) {
            self.mutex.unlock();
            try self.sendSystem(conn, .{
                .code = "name_taken",
                .message = "That name is already in use",
            });
            return;
        }

        if (state.name) |existing| {
            const key: []const u8 = existing;
            _ = self.players.remove(key);
            previous_name = existing;
            state.name = null;
        }

        try self.players.put(name_copy, Player{});
        state.name = name_copy;
        keep_name = true;

        self.mutex.unlock();

        if (previous_name) |old| self.allocator.free(old);

        log.info("player joined: {s}", .{name_slice});
        try self.sendSystem(conn, .{
            .code = "joined",
            .message = "You have joined the game",
        });
    }

    fn handleChat(
        self: *GameApp,
        conn: *ws.Conn,
        state: *ConnectionState,
        payload: messages.ChatPayload,
    ) !void {
        const player_name = state.name orelse {
            try self.sendSystem(conn, .{
                .code = "not_joined",
                .message = "Join the game before chatting",
            });
            return;
        };

        log.info("{s} says: {s}", .{ player_name, payload.message });

        try self.sendSystem(conn, .{
            .code = "chat_ack",
            .message = "Message received",
        });
    }

    fn handleMove(
        self: *GameApp,
        conn: *ws.Conn,
        state: *ConnectionState,
        payload: messages.MovePayload,
    ) !void {
        const player_name = state.name orelse {
            try self.sendSystem(conn, .{
                .code = "not_joined",
                .message = "Join the game before moving",
            });
            return;
        };

        log.debug("movement from {s}: ({d:.2}, {d:.2})", .{ player_name, payload.x, payload.y });

        try self.sendSystem(conn, .{
            .code = "move_ack",
            .message = "Position updated",
        });
    }

    fn handlePing(
        self: *GameApp,
        conn: *ws.Conn,
        _: *ConnectionState,
        _: messages.PingPayload,
    ) !void {
        try self.sendSystem(conn, .{
            .code = "pong",
            .message = "Heartbeat ok",
        });
    }

    fn sendSystem(
        self: *GameApp,
        conn: *ws.Conn,
        payload: messages.SystemPayload,
    ) !void {
        const frame = try messages.encodeMessage(self.allocator, "system", payload);
        defer self.allocator.free(frame);
        try conn.write(frame);
    }
};
