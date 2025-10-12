const std = @import("std");
const ws = @import("websocket");

const messages = @import("messages.zig");
const sqlite = @import("sqlite.zig");

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
    db: sqlite.Database,

    pub fn init(allocator: std.mem.Allocator) !GameApp {
        var self = GameApp{
            .allocator = allocator,
            .players = std.StringHashMap(Player).init(allocator),
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
            .db = try sqlite.Database.open(allocator, "game.db"),
        };
        errdefer self.deinit();

        try self.ensureSchema();
        try self.registerHandlerTyped(messages.JoinPayload, "join", handleJoin);
        try self.registerHandlerTyped(messages.ChatPayload, "chat", handleChat);
        try self.registerHandlerTyped(messages.MovePayload, "move", handleMove);
        try self.registerRequestHandlerTyped(
            messages.PingPayload,
            messages.SystemPayload,
            "ping",
            handlePing,
        );

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
        self.db.close();
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

    fn handleJoin(
        self: *GameApp,
        conn: *ws.Conn,
        state: *ConnectionState,
        payload: messages.JoinPayload,
    ) !void {
        const name_slice = payload.name;
        var previous_name: ?[]u8 = null;
        const stored_score = try self.fetchPlayerScore(name_slice);
        const initial_score: u32 = stored_score orelse 0;

        const name_copy_raw = try self.allocator.dupe(u8, name_slice);
        const name_copy = name_copy_raw;
        var keep_name = false;
        defer if (!keep_name) self.allocator.free(name_copy);

        self.mutex.lock();
        if (self.players.contains(name_slice)) {
            self.mutex.unlock();
            try self.sendMessage(conn, "system", .{
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

        try self.players.put(name_copy, Player{ .score = initial_score });
        state.name = name_copy;
        keep_name = true;

        self.mutex.unlock();

        if (previous_name) |old| self.allocator.free(old);
        try self.persistPlayerScore(name_slice, initial_score);

        log.info("player joined: {s}", .{name_slice});
        try self.sendMessage(conn, "system", .{
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
            try self.sendMessage(conn, "system", .{
                .code = "not_joined",
                .message = "Join the game before chatting",
            });
            return;
        };

        log.info("{s} says: {s}", .{ player_name, payload.message });

        try self.sendMessage(conn, "system", .{
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
            try self.sendMessage(conn, "system", .{
                .code = "not_joined",
                .message = "Join the game before moving",
            });
            return;
        };

        log.debug("movement from {s}: ({d:.2}, {d:.2})", .{ player_name, payload.x, payload.y });

        self.mutex.lock();
        const player_entry = self.players.getPtr(player_name) orelse {
            self.mutex.unlock();
            log.warn("move received for unknown player record: {s}", .{player_name});
            try self.sendMessage(conn, "system", .{
                .code = "not_registered",
                .message = "Player record missing",
            });
            return;
        };
        player_entry.*.score += 1;
        const updated_score = player_entry.*.score;
        self.mutex.unlock();

        try self.persistPlayerScore(player_name, updated_score);

        try self.sendMessage(conn, "system", .{
            .code = "move_ack",
            .message = "Position updated",
        });
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
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS players(
            \\    name TEXT PRIMARY KEY,
            \\    score INTEGER NOT NULL DEFAULT 0
            \\);
        );
    }

    fn persistPlayerScore(self: *GameApp, name: []const u8, score: u32) !void {
        var stmt = try self.db.prepare(
            \\INSERT INTO players(name, score)
            \\VALUES (?1, ?2)
            \\ON CONFLICT(name) DO UPDATE SET score = excluded.score;
        );
        defer stmt.finalize();

        try stmt.bindText(1, name);
        try stmt.bindInt(2, @as(i64, @intCast(score)));
        try stmt.stepExpectDone();
    }

    fn fetchPlayerScore(self: *GameApp, name: []const u8) !?u32 {
        var stmt = try self.db.prepare(
            \\SELECT score FROM players WHERE name = ?1;
        );
        defer stmt.finalize();

        try stmt.bindText(1, name);

        return switch (try stmt.step()) {
            .row => blk: {
                const raw = stmt.columnInt(0);
                if (raw < 0) {
                    log.warn("negative score found for {s}; resetting to zero", .{name});
                    break :blk 0;
                }
                const max_score = std.math.maxInt(u32);
                const max_score_i64 = @as(i64, max_score);
                if (raw > max_score_i64) {
                    log.warn("score overflow for {s}; clamping to {d}", .{ name, max_score });
                    break :blk max_score;
                }
                break :blk @as(u32, @intCast(raw));
            },
            .done => null,
        };
    }
};
