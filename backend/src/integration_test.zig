const std = @import("std");
const app = @import("app.zig");
const game_server = @import("game_server.zig");
const ws_test_client = @import("ws_test_client.zig");
const messages = @import("messages.zig");

test "integration: ping response" {
    const allocator = std.testing.allocator;

    std.debug.print("integration: opening cwd\n", .{});
    var original_dir = try std.fs.cwd().openDir(".", .{});
    defer original_dir.close();

    std.debug.print("integration: creating tmp dir\n", .{});
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    std.debug.print("integration: switching cwd\n", .{});
    try tmp_dir.dir.setAsCwd();
    defer original_dir.setAsCwd() catch {};

    const gpa_allocator = std.heap.c_allocator;

    std.debug.print("integration: initializing app\n", .{});
    var game_app = try app.GameApp.init(gpa_allocator);
    defer game_app.deinit();

    const port: u16 = 19876;

    std.debug.print("integration: starting server\n", .{});
    var server_instance = try game_server.start(&game_app, gpa_allocator, .{
        .address = "127.0.0.1",
        .port = port,
        .handshake_timeout = 5,
        .max_message_size = 2048,
        .thread_pool_count = 1,
    });
    defer {
        server_instance.stop();
        server_instance.deinit();
    }

    std.debug.print("integration: connecting client\n", .{});
    var client = try ws_test_client.TestClient.connect(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .path = "/",
        .handshake_timeout_ms = 2000,
    });
    defer client.deinit();

    {
        std.debug.print("integration: waiting for welcome\n", .{});
        var welcome = try client.expect(allocator, 2000, "system");
        defer welcome.deinit();

        const payload = try welcome.payloadAs(messages.SystemPayload);
        try std.testing.expectEqualStrings("connected", payload.code);
    }

    std.debug.print("integration: sending ping\n", .{});
    try client.sendMessage("ping", .{});
    {
        std.debug.print("integration: waiting for response\n", .{});
        var response = try client.expect(allocator, 2000, "response");
        defer response.deinit();

        const payload = try response.payloadAs(messages.ResponseEnvelope(messages.SystemPayload));
        try std.testing.expectEqualStrings("ping", payload.request);
        try std.testing.expectEqualStrings("pong", payload.data.code);
    }

    client.close();
}
