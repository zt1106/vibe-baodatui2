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

test "ws_test_client connects multiple clients" {
    try ws_test_client.withReadyClient(22002, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const second = try ctx.connectReadyClient(2000, null);

            const first_payload = try ctx.client.request(ctx.allocator, 2000, "ping", messages.PingPayload{}, messages.SystemPayload);
            try std.testing.expectEqualStrings("pong", first_payload.code);

            const second_payload = try second.request(ctx.allocator, 2000, "ping", messages.PingPayload{}, messages.SystemPayload);
            try std.testing.expectEqualStrings("pong", second_payload.code);
        }
    }.run);
}
