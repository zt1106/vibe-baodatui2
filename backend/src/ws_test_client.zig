const std = @import("std");
const websocket = @import("websocket");

const messages = @import("messages.zig");
const game_server = @import("game_server.zig");
const test_support = @import("test_support.zig");

const ws_client = websocket.Client;

pub const ClientError = error{
    ConnectionClosed,
    UnexpectedBinaryPayload,
    UnexpectedMessageType,
    Timeout,
};

test "ws_test_client connects and handles ping" {
    try withReadyClient(22001, struct {
        fn run(ctx: *IntegrationContext) !void {
            const payload = try ctx.client.request(ctx.allocator, 2000, "ping", messages.PingPayload{}, messages.SystemPayload);
            try std.testing.expectEqualStrings("pong", payload.code);
        }
    }.run);
}

pub const IntegrationContext = struct {
    allocator: std.mem.Allocator,
    server: test_support.GameServerFixture,
    client: TestClient,

    fn deinit(self: *IntegrationContext) void {
        self.client.close();
        self.client.deinit();
        self.server.shutdown();
        self.* = undefined;
    }
};

fn setupServerAndClient(allocator: std.mem.Allocator, port: u16) !IntegrationContext {
    var server_fixture = try test_support.spawnServer(allocator, .{
        .address = "127.0.0.1",
        .port = port,
        .handshake_timeout = 5,
        .max_message_size = 2048,
        .thread_pool_count = 1,
    });
    errdefer {
        server_fixture.shutdown();
    }

    var client = try TestClient.connect(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .path = "/",
        .handshake_timeout_ms = 2000,
    });
    errdefer {
        client.close();
        client.deinit();
    }

    return IntegrationContext{
        .allocator = allocator,
        .server = server_fixture,
        .client = client,
    };
}

pub fn withReadyClient(port: u16, callback: anytype) !void {
    const CallbackFn = *const fn (*IntegrationContext) anyerror!void;
    const cb: CallbackFn = callback;

    const Runner = struct {
        port: u16,
        callback: CallbackFn,

        fn run(self: *@This()) !void {
            var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();

            var ctx = try setupReadyClient(allocator, self.port);
            defer ctx.deinit();

            try self.callback(&ctx);
        }
    };

    var runner = Runner{
        .port = port,
        .callback = cb,
    };

    try test_support.withTempDirContext(@TypeOf(runner), Runner.run, &runner);
}

pub fn setupReadyClient(allocator: std.mem.Allocator, port: u16) !IntegrationContext {
    var ctx = try setupServerAndClient(allocator, port);
    errdefer ctx.deinit();

    var welcome = try ctx.client.expectCall(allocator, 2000, "system");
    defer welcome.deinit();
    const welcome_call = try welcome.call();
    const welcome_payload = try welcome_call.paramsAs(messages.SystemPayload);
    try std.testing.expectEqualStrings("connected", welcome_payload.code);

    return ctx;
}

pub const TestClient = struct {
    allocator: std.mem.Allocator,
    client: ws_client,
    next_id: i64 = 1,

    pub const Config = struct {
        host: []const u8 = "127.0.0.1",
        port: u16,
        path: []const u8 = "/",
        tls: bool = false,
        handshake_timeout_ms: u32 = 5000,
        max_frame_size: usize = 65536,
        buffer_size: usize = 4096,
    };

    pub fn connect(allocator: std.mem.Allocator, config: Config) !TestClient {
        var client = try ws_client.init(allocator, .{
            .host = config.host,
            .port = config.port,
            .tls = config.tls,
            .max_size = config.max_frame_size,
            .buffer_size = config.buffer_size,
        });
        errdefer client.deinit();

        try client.handshake(config.path, .{ .timeout_ms = config.handshake_timeout_ms });

        return .{
            .allocator = allocator,
            .client = client,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *TestClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn close(self: *TestClient) void {
        self.client.close(.{}) catch {};
    }

    pub fn sendRequest(self: *TestClient, method: []const u8, params: anytype) !messages.Id {
        const id_value = self.next_id;
        self.next_id += 1;
        const id = messages.Id.fromInt(id_value);
        const frame = try messages.encodeRequest(self.allocator, method, params, id);
        defer self.allocator.free(frame);
        try self.client.write(frame);
        return id;
    }

    pub fn request(self: *TestClient, allocator: std.mem.Allocator, timeout_ms: u32, method: []const u8, params: anytype, comptime ResponseType: type) !ResponseType {
        const id = try self.sendRequest(method, params);
        var frame = try self.expectResponse(allocator, timeout_ms, id);
        defer frame.deinit();
        const response = try frame.response();
        return try response.resultAs(ResponseType);
    }

    pub fn sendNotification(self: *TestClient, method: []const u8, params: anytype) !void {
        const frame = try messages.encodeNotification(self.allocator, method, params);
        defer self.allocator.free(frame);
        try self.client.write(frame);
    }

    pub fn sendRaw(self: *TestClient, data: []const u8) !void {
        const copy = try self.allocator.alloc(u8, data.len);
        defer self.allocator.free(copy);
        std.mem.copy(u8, copy, data);
        try self.client.write(copy);
    }

    fn receiveWithDeadline(
        self: *TestClient,
        allocator: std.mem.Allocator,
        deadline_ms: i128,
    ) (ClientError || error{Timeout} || anyerror)!messages.Frame {
        while (true) {
            const now = std.time.milliTimestamp();
            if (now >= deadline_ms) return error.Timeout;

            const remaining_ms: u64 = @intCast(deadline_ms - now);
            const wait_ms: u32 = if (remaining_ms > std.math.maxInt(u32))
                std.math.maxInt(u32)
            else
                @intCast(remaining_ms);

            try self.client.readTimeout(wait_ms);

            const maybe = self.client.read() catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                },
                error.ConnectionResetByPeer, error.Closed => return error.ConnectionClosed,
                else => return err,
            };

            if (maybe) |frame| {
                defer self.client.done(frame);
                switch (frame.type) {
                    .text => {
                        return try messages.parseFrame(allocator, frame.data);
                    },
                    .binary => return error.UnexpectedBinaryPayload,
                    .close => return error.ConnectionClosed,
                    .ping => {
                        try self.client.writePong(frame.data);
                        continue;
                    },
                    .pong => continue,
                }
            }
        }
    }

    pub fn receive(
        self: *TestClient,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
    ) (ClientError || anyerror)!messages.Frame {
        const deadline = std.time.milliTimestamp() + @as(i128, timeout_ms);
        return self.receiveWithDeadline(allocator, deadline) catch |err| switch (err) {
            error.Timeout => ClientError.Timeout,
        };
    }

    pub fn expectCall(
        self: *TestClient,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
        method: []const u8,
    ) (ClientError || anyerror)!messages.Frame {
        const deadline = std.time.milliTimestamp() + @as(i128, timeout_ms);
        var frame = self.receiveWithDeadline(allocator, deadline) catch |err| switch (err) {
            error.Timeout => return ClientError.Timeout,
            else => return err,
        };

        switch (frame.kind()) {
            .call => {
                const call = try frame.call();
                if (!std.mem.eql(u8, call.methodName(), method)) {
                    frame.deinit();
                    return error.UnexpectedMessageType;
                }
            },
            else => {
                frame.deinit();
                return error.UnexpectedMessageType;
            },
        }

        return frame;
    }

    pub fn expectResponse(
        self: *TestClient,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
        id: messages.Id,
    ) (ClientError || anyerror)!messages.Frame {
        const deadline = std.time.milliTimestamp() + @as(i128, timeout_ms);
        var frame = self.receiveWithDeadline(allocator, deadline) catch |err| switch (err) {
            error.Timeout => return ClientError.Timeout,
            else => return err,
        };

        switch (frame.kind()) {
            .response => {
                const response = try frame.response();
                if (!messages.idsEqual(response.idValue(), id)) {
                    frame.deinit();
                    return error.UnexpectedMessageType;
                }
            },
            .rpc_error => {
                const err = try frame.rpcError();
                if (err.idValue()) |err_id| {
                    if (!messages.idsEqual(err_id, id)) {
                        frame.deinit();
                        return error.UnexpectedMessageType;
                    }
                } else {
                    frame.deinit();
                    return error.UnexpectedMessageType;
                }
            },
            else => {
                frame.deinit();
                return error.UnexpectedMessageType;
            },
        }

        return frame;
    }
};
