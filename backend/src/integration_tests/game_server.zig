const std = @import("std");
const messages = @import("../messages.zig");
const test_support = @import("../test_support.zig");
const ws_test_client = @import("../ws_test_client.zig");

test "game_server sends welcome message on connect" {
    try test_support.withTempDir(struct {
        fn run() !void {
            const allocator = std.testing.allocator;

            const port: u16 = 21001;
            var fixture = try test_support.spawnServer(allocator, .{
                .address = "127.0.0.1",
                .port = port,
                .handshake_timeout = 5,
                .max_message_size = 2048,
                .thread_pool_count = 1,
            });
            defer {
                fixture.shutdown();
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

            var welcome = try client.expectCall(allocator, 2000, "system");
            defer welcome.deinit();

            const call = try welcome.call();
            const payload = try call.paramsAs(messages.SystemPayload);
            try std.testing.expectEqualStrings("connected", payload.code);
            try std.testing.expectEqualStrings("Welcome to the game server", payload.message);
        }
    }.run);
}

test "game_server returns system error for unknown message" {
    try test_support.withTempDir(struct {
        fn run() !void {
            const allocator = std.testing.allocator;

            const port: u16 = 21002;
            var fixture = try test_support.spawnServer(allocator, .{
                .address = "127.0.0.1",
                .port = port,
                .handshake_timeout = 5,
                .max_message_size = 2048,
                .thread_pool_count = 1,
            });
            defer {
                fixture.shutdown();
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

            var welcome = try client.expectCall(allocator, 2000, "system");
            defer welcome.deinit();

            const call = try welcome.call();
            _ = try call.paramsAs(messages.SystemPayload);

            const id = try client.sendRequest("unknown_message", messages.EmptyParams{});

            var response_frame = try client.expectResponse(allocator, 2000, id);
            defer response_frame.deinit();

            switch (response_frame.kind()) {
                .rpc_error => {
                    const err = try response_frame.rpcError();
                    try std.testing.expect(err.codeValue() == -32601);
                    try std.testing.expectEqualStrings("Method not found", err.messageValue());
                },
                else => return error.UnexpectedMessageType,
            }
        }
    }.run);
}

