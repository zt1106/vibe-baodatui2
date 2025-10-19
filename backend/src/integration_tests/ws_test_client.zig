const std = @import("std");
const messages = @import("../messages.zig");
const ws_test_client = @import("../ws_test_client.zig");

test "ws_test_client connects and handles ping" {
    try ws_test_client.withReadyClient(22001, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const payload = try ctx.client.request(ctx.allocator, 2000, "ping", messages.PingPayload{}, messages.SystemPayload);
            try std.testing.expectEqualStrings("pong", payload.code);
        }
    }.run);
}

