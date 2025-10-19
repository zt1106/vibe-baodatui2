const std = @import("std");
const messages = @import("../messages.zig");
const ws_test_client = @import("../ws_test_client.zig");

test "integration: room lobby flow" {
    const port: u16 = 22031;
    try ws_test_client.withReadyClient(port, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const allocator = ctx.allocator;
            const host = &ctx.client;

            const host_payload = try host.request(allocator, 2000, "user_set_name", messages.UserSetNamePayload{ .nickname = "Alice" }, messages.UserInfoPayload);
            const host_id = host_payload.id;

            const created_payload = try host.request(allocator, 2000, "room_create", messages.RoomCreatePayload{
                .player_limit = 4,
            }, messages.RoomDetailPayload);
            const room_id = created_payload.id;
            try std.testing.expectEqual(@as(u8, 4), created_payload.config.player_limit);
            try std.testing.expectEqual(host_id, created_payload.host_id);
            try std.testing.expectEqual(@as(usize, 1), created_payload.players.len);
            try std.testing.expect(created_payload.players[0].is_host);
            try std.testing.expectEqual(host_id, created_payload.players[0].user_id);

            const list_payload = try host.request(allocator, 2000, "room_list", messages.RoomListRequestPayload{}, messages.RoomListResponsePayload);
            try std.testing.expectEqual(@as(usize, 1), list_payload.rooms.len);
            const first_room = list_payload.rooms[0];
            try std.testing.expectEqual(room_id, first_room.id);
            try std.testing.expectEqual(messages.RoomStatePayload.waiting, first_room.state);

            var guest = try ws_test_client.TestClient.connect(allocator, .{
                .host = "127.0.0.1",
                .port = port,
                .path = "/",
                .handshake_timeout_ms = 2000,
            });
            defer {
                guest.close();
                guest.deinit();
            }

            var guest_welcome = try guest.expectCall(allocator, 2000, "system");
            defer guest_welcome.deinit();
            const guest_welcome_call = try guest_welcome.call();
            const guest_welcome_payload = try guest_welcome_call.paramsAs(messages.SystemPayload);
            try std.testing.expectEqualStrings("connected", guest_welcome_payload.code);

            const guest_payload = try guest.request(allocator, 2000, "user_set_name", messages.UserSetNamePayload{ .nickname = "Bob" }, messages.UserInfoPayload);
            const guest_id = guest_payload.id;

            const joined_payload = try guest.request(allocator, 2000, "room_join", messages.RoomJoinPayload{ .room_id = room_id }, messages.RoomDetailPayload);
            try std.testing.expectEqual(@as(usize, 2), joined_payload.players.len);
            try std.testing.expectEqual(guest_id, joined_payload.players[1].user_id);

            const updated_config = try host.request(allocator, 2000, "room_config_update", messages.RoomConfigUpdatePayload{ .player_limit = 6 }, messages.RoomDetailPayload);
            try std.testing.expectEqual(@as(u8, 6), updated_config.config.player_limit);
            try std.testing.expectEqual(@as(usize, 2), updated_config.players.len);

            var guest_two = try ws_test_client.TestClient.connect(allocator, .{
                .host = "127.0.0.1",
                .port = port,
                .path = "/",
                .handshake_timeout_ms = 2000,
            });
            defer {
                guest_two.close();
                guest_two.deinit();
            }

            var guest_two_welcome = try guest_two.expectCall(allocator, 2000, "system");
            defer guest_two_welcome.deinit();
            const guest_two_welcome_call = try guest_two_welcome.call();
            const guest_two_welcome_payload = try guest_two_welcome_call.paramsAs(messages.SystemPayload);
            try std.testing.expectEqualStrings("connected", guest_two_welcome_payload.code);

            const guest_two_payload = try guest_two.request(allocator, 2000, "user_set_name", messages.UserSetNamePayload{ .nickname = "Charlie" }, messages.UserInfoPayload);
            const guest_two_id = guest_two_payload.id;

            const joined_two_payload = try guest_two.request(allocator, 2000, "room_join", messages.RoomJoinPayload{ .room_id = room_id }, messages.RoomDetailPayload);
            try std.testing.expectEqual(@as(usize, 3), joined_two_payload.players.len);
            try std.testing.expectEqual(guest_two_id, joined_two_payload.players[2].user_id);

            const host_ready_payload = try host.request(allocator, 2000, "room_ready", messages.RoomReadyPayload{ .prepared = true }, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, host_ready_payload.players[0].state);

            const guest_ready_payload = try guest.request(allocator, 2000, "room_ready", messages.RoomReadyPayload{ .prepared = true }, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, guest_ready_payload.players[1].state);
            try std.testing.expectEqual(@as(usize, 3), guest_ready_payload.players.len);

            const guest_two_ready_payload = try guest_two.request(allocator, 2000, "room_ready", messages.RoomReadyPayload{ .prepared = true }, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, guest_two_ready_payload.players[2].state);

            const started_payload = try host.request(allocator, 2000, "room_start", messages.RoomStartPayload{}, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomStatePayload.in_game, started_payload.state);
        }
    }.run);
}
