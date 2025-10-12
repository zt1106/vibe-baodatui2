const std = @import("std");

pub const messages = @import("messages.zig");
pub const game_server = @import("game_server.zig");
pub const app = @import("app.zig");

test "messages roundtrip" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"type":"ping","data":{}}
    ;

    var parsed = try messages.parseMessage(allocator, raw);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ping", parsed.typeName());
}
