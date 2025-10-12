const std = @import("std");
const ws = @import("websocket");

const messages = @import("messages.zig");
const app = @import("app.zig");
const ws_test_client = @import("ws_test_client.zig");

const log = std.log.scoped(.game_server);

pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 7998,
    handshake_timeout: u32 = 5,
    max_message_size: u16 = 1024,
    thread_pool_count: ?u16 = null,
};

pub const Instance = struct {
    server: *ws.Server(Handler),
    thread: std.Thread,
    ctx: *HandlerContext,
    allocator: std.mem.Allocator,

    pub fn wait(self: *Instance) void {
        self.thread.join();
    }

    pub fn stop(self: *Instance) void {
        self.server.stop();
        self.thread.join();
    }

    pub fn deinit(self: *Instance) void {
        self.server.deinit();
        self.allocator.destroy(self.server);
        self.allocator.destroy(self.ctx);
    }
};

pub fn start(game_app: *app.GameApp, allocator: std.mem.Allocator, config: Config) !Instance {
    const ctx = try allocator.create(HandlerContext);
    ctx.* = .{
        .allocator = allocator,
        .app = game_app,
    };
    errdefer allocator.destroy(ctx);

    const server_ptr = try allocator.create(ws.Server(Handler));
    errdefer allocator.destroy(server_ptr);

    server_ptr.* = try ws.Server(Handler).init(allocator, .{
        .port = config.port,
        .address = config.address,
        .handshake = .{
            .timeout = config.handshake_timeout,
            .max_size = config.max_message_size,
            .max_headers = 0,
        },
        .thread_pool = .{
            .count = config.thread_pool_count,
        },
    });
    errdefer server_ptr.deinit();

    const thread = try server_ptr.listenInNewThread(ctx);

    return .{
        .server = server_ptr,
        .thread = thread,
        .ctx = ctx,
        .allocator = allocator,
    };
}

pub fn run(game_app: *app.GameApp, allocator: std.mem.Allocator, config: Config) !void {
    var instance = try start(game_app, allocator, config);
    defer instance.deinit();

    log.info("starting websocket server on {s}:{d}", .{ config.address, config.port });
    instance.wait();
}

const HandlerContext = struct {
    allocator: std.mem.Allocator,
    app: *app.GameApp,
};

const Handler = struct {
    allocator: std.mem.Allocator,
    conn: *ws.Conn,
    app: *app.GameApp,
    state: app.ConnectionState,

    pub fn init(_: *ws.Handshake, conn: *ws.Conn, ctx: *HandlerContext) !Handler {
        return .{
            .allocator = ctx.allocator,
            .conn = conn,
            .app = ctx.app,
            .state = .{},
        };
    }

    pub fn afterInit(self: *Handler) !void {
        try self.app.onConnect(self.conn, &self.state);
    }

    pub fn clientMessage(self: *Handler, data: []const u8) !void {
        var message = messages.parseMessage(self.allocator, data) catch |err| {
            log.warn("invalid message from client: {}", .{err});
            try self.sendSystemError("invalid_message", "Message could not be parsed");
            return;
        };
        defer message.deinit();

        self.app.onMessage(self.conn, &self.state, &message) catch |err| {
            log.err("handler error: {}", .{err});
            try self.sendSystemError("handler_error", @errorName(err));
        };
    }

    pub fn close(self: *Handler) void {
        self.app.onDisconnect(&self.state);
    }

    fn sendSystemError(self: *Handler, code: []const u8, message: []const u8) !void {
        const payload = messages.SystemPayload{
            .code = code,
            .message = message,
        };
        const frame = try messages.encodeMessage(self.allocator, "system", payload);
        defer self.allocator.free(frame);
        try self.conn.write(frame);
    }
};

fn withTempDir(action: anytype) !void {
    var original_dir = try std.fs.cwd().openDir(".", .{});
    defer original_dir.close();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_dir.setAsCwd() catch {};

    try action();
}

test "game_server sends welcome message on connect" {
    try withTempDir(struct {
        fn run() !void {
            const allocator = std.testing.allocator;

            var game_app = try app.GameApp.init(allocator);
            defer game_app.deinit();

            const port: u16 = 21001;
            var server = try start(&game_app, allocator, .{
                .address = "127.0.0.1",
                .port = port,
                .handshake_timeout = 5,
                .max_message_size = 2048,
                .thread_pool_count = 1,
            });
            defer {
                server.stop();
                server.deinit();
            }

            var client = try ws_test_client.TestClient.connect(allocator, .{
                .host = "127.0.0.1",
                .port = port,
                .path = "/",
                .handshake_timeout_ms = 2000,
            });
            defer {
                client.close();
                client.deinit();
            }

            var welcome = try client.expect(allocator, 2000, "system");
            defer welcome.deinit();

            const payload = try welcome.payloadAs(messages.SystemPayload);
            try std.testing.expectEqualStrings("connected", payload.code);
            try std.testing.expectEqualStrings("Welcome to the game server", payload.message);
        }
    }.run);
}

test "game_server returns system error for unknown message" {
    try withTempDir(struct {
        fn run() !void {
            const allocator = std.testing.allocator;

            var game_app = try app.GameApp.init(allocator);
            defer game_app.deinit();

            const port: u16 = 21002;
            var server = try start(&game_app, allocator, .{
                .address = "127.0.0.1",
                .port = port,
                .handshake_timeout = 5,
                .max_message_size = 2048,
                .thread_pool_count = 1,
            });
            defer {
                server.stop();
                server.deinit();
            }

            var client = try ws_test_client.TestClient.connect(allocator, .{
                .host = "127.0.0.1",
                .port = port,
                .path = "/",
                .handshake_timeout_ms = 2000,
            });
            defer {
                client.close();
                client.deinit();
            }

            var welcome = try client.expect(allocator, 2000, "system");
            defer welcome.deinit();

            _ = try welcome.payloadAs(messages.SystemPayload);

            try client.sendMessage("unknown_message", .{});

            var response = try client.expect(allocator, 2000, "system");
            defer response.deinit();

            const payload = try response.payloadAs(messages.SystemPayload);
            try std.testing.expectEqualStrings("unknown_type", payload.code);
        }
    }.run);
}
