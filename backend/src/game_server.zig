const std = @import("std");
const ws = @import("websocket");

const messages = @import("messages.zig");
const app = @import("app.zig");

const log = std.log.scoped(.game_server);

pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 7998,
    handshake_timeout: u32 = 5,
    max_message_size: u16 = 1024,
};

pub fn run(game_app: *app.GameApp, allocator: std.mem.Allocator, config: Config) !void {
    var server = try ws.Server(Handler).init(allocator, .{
        .port = config.port,
        .address = config.address,
        .handshake = .{
            .timeout = config.handshake_timeout,
            .max_size = config.max_message_size,
            .max_headers = 0,
        },
    });
    defer server.deinit();

    var ctx = HandlerContext{
        .allocator = allocator,
        .app = game_app,
    };

    log.info("starting websocket server on {s}:{d}", .{ config.address, config.port });
    try server.listen(&ctx);
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
