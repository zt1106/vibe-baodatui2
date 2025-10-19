const std = @import("std");

pub const game_server = @import("game_server.zig");
pub const room_service = @import("room_service.zig");
pub const user_service = @import("user_service.zig");
pub const ws_test_client = @import("ws_test_client.zig");

test "integration modules wired" {
    std.testing.refAllDecls(game_server);
    std.testing.refAllDecls(room_service);
    std.testing.refAllDecls(user_service);
    std.testing.refAllDecls(ws_test_client);
}

