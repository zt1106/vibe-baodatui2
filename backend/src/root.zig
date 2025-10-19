const std = @import("std");

pub const messages = @import("messages.zig");
pub const game_server = @import("game_server.zig");
pub const app = @import("app.zig");
const user_service = @import("user_service.zig");
pub const room_service = @import("room_service.zig");
pub const ws_test_client = @import("ws_test_client.zig");
pub const integration_tests = @import("integration_tests/root.zig");

test "messages roundtrip" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
    ;

    var frame = try messages.parseFrame(allocator, raw);
    defer frame.deinit();

    try std.testing.expectEqual(messages.PayloadTag.call, frame.kind());
    const call = try frame.call();
    try std.testing.expect(!call.isNotification());
    try std.testing.expectEqualStrings("ping", call.methodName());
}

test "all module tests are wired" {
    std.testing.refAllDecls(messages);
    std.testing.refAllDecls(game_server);
    std.testing.refAllDecls(app);
    std.testing.refAllDecls(user_service);
    std.testing.refAllDecls(room_service);
    std.testing.refAllDecls(ws_test_client);
    std.testing.refAllDecls(integration_tests);
}
