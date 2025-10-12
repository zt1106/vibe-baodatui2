const std = @import("std");
const websocket = @import("websocket");

const messages = @import("messages.zig");

const ws_client = websocket.Client;

pub const ClientError = error{
    ConnectionClosed,
    UnexpectedBinaryPayload,
    UnexpectedMessageType,
};

pub const TestClient = struct {
    allocator: std.mem.Allocator,
    client: ws_client,

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
        };
    }

    pub fn deinit(self: *TestClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn close(self: *TestClient) void {
        self.client.close(.{}) catch {};
    }

    pub fn sendMessage(self: *TestClient, type_name: []const u8, payload: anytype) !void {
        const frame = try messages.encodeMessage(self.allocator, type_name, payload);
        defer self.allocator.free(frame);
        try self.client.write(frame);
    }

    pub fn sendRaw(self: *TestClient, data: []const u8) !void {
        const copy = try self.allocator.alloc(u8, data.len);
        defer self.allocator.free(copy);
        std.mem.copy(u8, copy, data);
        try self.client.write(copy);
    }

    pub fn receive(
        self: *TestClient,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
    ) (ClientError || anyerror)!messages.Message {
        try self.client.readTimeout(timeout_ms);

        while (true) {
            const maybe = try self.client.read();
            if (maybe) |frame| {
                defer self.client.done(frame);
                switch (frame.type) {
                    .text => {
                        return try messages.parseMessage(allocator, frame.data);
                    },
                    .binary => return error.UnexpectedBinaryPayload,
                    .close => return error.ConnectionClosed,
                    .ping => {
                        try self.client.writePong(frame.data);
                        continue;
                    },
                    .pong => continue,
                }
            } else {
                try self.client.readTimeout(timeout_ms);
            }
        }
    }

    pub fn expect(
        self: *TestClient,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
        type_name: []const u8,
    ) (ClientError || anyerror)!messages.Message {
        while (true) {
            var message = try self.receive(allocator, timeout_ms);
            if (std.mem.eql(u8, message.typeName(), type_name)) {
                return message;
            }
            message.deinit();
        }
    }
};
