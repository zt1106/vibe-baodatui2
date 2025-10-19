const std = @import("std");
const messages = @import("../messages.zig");
const ws_test_client = @import("../ws_test_client.zig");

test "integration: user set name and rename" {
    try ws_test_client.withReadyClient(22021, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const allocator = ctx.allocator;

            const set_payload = try ctx.client.request(allocator, 2000, "user_set_name", messages.UserSetNamePayload{ .nickname = "Alice" }, messages.UserInfoPayload);
            const user_id = set_payload.id;

            const rename_payload = try ctx.client.request(allocator, 2000, "user_set_name", messages.UserSetNamePayload{ .nickname = "Alice Updated" }, messages.UserInfoPayload);
            try std.testing.expectEqual(user_id, rename_payload.id);
            try std.testing.expectEqualStrings("Alice Updated", rename_payload.username);
        }
    }.run);
}
