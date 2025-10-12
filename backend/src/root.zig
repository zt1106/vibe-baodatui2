const std = @import("std");

pub const messages = @import("messages.zig");
pub const game_server = @import("game_server.zig");
pub const app = @import("app.zig");
const sqlite = @import("sqlite.zig");
const user_service = @import("user_service.zig");
pub const ws_test_client = @import("ws_test_client.zig");
const integration_test = @import("integration_test.zig");

test "messages roundtrip" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"type":"ping","data":{}}
    ;

    var parsed = try messages.parseMessage(allocator, raw);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ping", parsed.typeName());
}

test "all module tests are wired" {
    std.testing.refAllDecls(messages);
    std.testing.refAllDecls(game_server);
    std.testing.refAllDecls(app);
    std.testing.refAllDecls(sqlite);
    std.testing.refAllDecls(user_service);
    std.testing.refAllDecls(ws_test_client);
    std.testing.refAllDecls(integration_test);
}
