const std = @import("std");
const messages = @import("messages.zig");
const ws_test_client = @import("ws_test_client.zig");

pub const Error = error{
    NotLoggedIn,
    MissingUsername,
    AlreadyInRoom,
    RoomNameExists,
    InvalidRoomName,
    InvalidPlayerLimit,
    RoomNotFound,
    RoomFull,
    RoomInProgress,
    NotInRoom,
    NotHost,
    PlayersNotReady,
};

pub const RoomListView = struct {
    allocator: std.mem.Allocator,
    owned: []messages.RoomSummaryPayload,
    payload: messages.RoomListResponsePayload,

    pub fn deinit(self: *RoomListView) void {
        if (self.owned.len > 0) {
            self.allocator.free(self.owned);
        }
        self.* = undefined;
    }
};

pub const RoomService = struct {
    allocator: std.mem.Allocator,
    rooms: std.AutoHashMap(u32, Room),
    rooms_by_name: std.StringHashMap(u32),
    user_to_room: std.AutoHashMap(i64, u32),
    next_room_id: u32 = 1,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) RoomService {
        return .{
            .allocator = allocator,
            .rooms = std.AutoHashMap(u32, Room).init(allocator),
            .rooms_by_name = std.StringHashMap(u32).init(allocator),
            .user_to_room = std.AutoHashMap(i64, u32).init(allocator),
        };
    }

    pub fn deinit(self: *RoomService) void {
        var it = self.rooms.valueIterator();
        while (it.next()) |room| {
            room.deinit(self.allocator);
        }
        self.rooms.deinit();
        self.rooms_by_name.deinit();
        self.user_to_room.deinit();
    }

    pub fn listRooms(
        self: *RoomService,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!RoomListView {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.rooms.count();
        if (count == 0) {
            return RoomListView{
                .allocator = allocator,
                .owned = &[_]messages.RoomSummaryPayload{},
                .payload = .{ .rooms = &[_]messages.RoomSummaryPayload{} },
            };
        }

        const buffer = try allocator.alloc(messages.RoomSummaryPayload, count);
        errdefer allocator.free(buffer);

        var vit = self.rooms.valueIterator();
        var index: usize = 0;
        while (vit.next()) |room| {
            buffer[index] = .{
                .id = room.id,
                .name = room.name,
                .state = room.state,
                .player_count = @intCast(room.players.items.len),
                .player_limit = room.config.player_limit,
            };
            index += 1;
        }

        return RoomListView{
            .allocator = allocator,
            .owned = buffer,
            .payload = .{ .rooms = buffer[0..index] },
        };
    }

    pub fn createRoom(
        self: *RoomService,
        user_id: ?i64,
        username: ?[]const u8,
        payload: messages.RoomCreatePayload,
    ) (Error || std.mem.Allocator.Error)!messages.RoomDetailPayload {
        const uid = user_id orelse return Error.NotLoggedIn;
        const uname = username orelse return Error.MissingUsername;

        const trimmed_name = try normalizeRoomName(payload.name);
        try ensurePlayerLimit(payload.player_limit);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.user_to_room.contains(uid)) {
            return Error.AlreadyInRoom;
        }
        if (self.rooms_by_name.contains(trimmed_name)) {
            return Error.RoomNameExists;
        }

        const room_id = self.next_room_id;
        self.next_room_id += 1;

        const name_copy = try self.allocator.dupe(u8, trimmed_name);
        errdefer self.allocator.free(name_copy);

        var room = Room{
            .id = room_id,
            .name = name_copy,
            .state = .waiting,
            .config = .{ .player_limit = payload.player_limit },
            .host_user_id = uid,
        };
        errdefer room.deinit(self.allocator);

        const host_name_copy = try self.allocator.dupe(u8, uname);
        var host_added = false;
        defer if (!host_added) self.allocator.free(host_name_copy);

        try room.players.append(self.allocator, .{
            .user_id = uid,
            .username = host_name_copy,
            .state = .not_prepared,
            .is_host = true,
        });
        host_added = true;

        try self.rooms.put(room.id, room);
        const stored_room = self.rooms.getPtr(room.id) orelse unreachable;
        try self.rooms_by_name.put(stored_room.name, room.id);
        try self.user_to_room.put(uid, room.id);

        return snapshotRoom(stored_room);
    }

    pub fn joinRoom(
        self: *RoomService,
        user_id: ?i64,
        username: ?[]const u8,
        payload: messages.RoomJoinPayload,
    ) (Error || std.mem.Allocator.Error)!messages.RoomDetailPayload {
        const uid = user_id orelse return Error.NotLoggedIn;
        const uname = username orelse return Error.MissingUsername;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.user_to_room.contains(uid)) {
            return Error.AlreadyInRoom;
        }

        const room = self.rooms.getPtr(payload.room_id) orelse return Error.RoomNotFound;

        if (room.state == .in_game) {
            return Error.RoomInProgress;
        }
        if (room.players.items.len >= room.config.player_limit) {
            return Error.RoomFull;
        }

        const name_copy = try self.allocator.dupe(u8, uname);
        var added = false;
        defer if (!added) self.allocator.free(name_copy);

        try room.players.append(self.allocator, .{
            .user_id = uid,
            .username = name_copy,
            .state = .not_prepared,
            .is_host = false,
        });
        added = true;

        try self.user_to_room.put(uid, room.id);

        return snapshotRoom(room);
    }

    pub fn leaveRoom(
        self: *RoomService,
        user_id: ?i64,
    ) Error!messages.RoomLeaveResponsePayload {
        const uid = user_id orelse return Error.NotLoggedIn;

        self.mutex.lock();
        defer self.mutex.unlock();

        const room_id_ptr = self.user_to_room.getPtr(uid) orelse return Error.NotInRoom;
        const room_id = room_id_ptr.*;

        const room = self.rooms.getPtr(room_id) orelse return Error.RoomNotFound;
        try tryRemovePlayer(self, room, uid);
        _ = self.user_to_room.remove(uid);

        if (room.players.items.len == 0) {
            removeRoomLocked(self, room_id);
        }

        return .{ .room_id = room_id };
    }

    pub fn setPrepared(
        self: *RoomService,
        user_id: ?i64,
        payload: messages.RoomReadyPayload,
    ) Error!messages.RoomDetailPayload {
        const uid = user_id orelse return Error.NotLoggedIn;

        self.mutex.lock();
        defer self.mutex.unlock();

        const room_id = self.user_to_room.get(uid) orelse return Error.NotInRoom;
        const room = self.rooms.getPtr(room_id) orelse return Error.RoomNotFound;

        if (room.state == .in_game) {
            return Error.RoomInProgress;
        }

        const index = room.playerIndex(uid) orelse return Error.NotInRoom;
        room.players.items[index].state = if (payload.prepared)
            .prepared
        else
            .not_prepared;

        return snapshotRoom(room);
    }

    pub fn startGame(
        self: *RoomService,
        user_id: ?i64,
    ) Error!messages.RoomDetailPayload {
        const uid = user_id orelse return Error.NotLoggedIn;

        self.mutex.lock();
        defer self.mutex.unlock();

        const room_id = self.user_to_room.get(uid) orelse return Error.NotInRoom;
        const room = self.rooms.getPtr(room_id) orelse return Error.RoomNotFound;

        if (room.state == .in_game) {
            return Error.RoomInProgress;
        }
        if (room.host_user_id != uid) {
            return Error.NotHost;
        }

        var all_ready = true;
        for (room.players.items) |player| {
            if (player.state != .prepared) {
                all_ready = false;
                break;
            }
        }
        if (!all_ready) {
            return Error.PlayersNotReady;
        }

        room.state = .in_game;
        return snapshotRoom(room);
    }

    pub fn handleDisconnect(self: *RoomService, user_id: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.user_to_room.fetchRemove(user_id) orelse return;
        const room_id = entry.value;
        const room = self.rooms.getPtr(room_id) orelse return;
        tryRemovePlayer(self, room, user_id) catch {};

        if (room.players.items.len == 0) {
            removeRoomLocked(self, room_id);
        }
    }
};

const GameConfig = struct {
    player_limit: u8,
};

const Room = struct {
    id: u32,
    name: []u8,
    state: messages.RoomStatePayload,
    config: GameConfig,
    host_user_id: i64,
    players: std.ArrayList(messages.RoomPlayerPayload) = .empty,

    fn deinit(self: *Room, allocator: std.mem.Allocator) void {
        for (self.players.items) |player| {
            allocator.free(@constCast(player.username));
        }
        self.players.deinit(allocator);
        allocator.free(self.name);
    }

    fn playerIndex(self: *Room, user_id: i64) ?usize {
        for (self.players.items, 0..) |player, index| {
            if (player.user_id == user_id) {
                return index;
            }
        }
        return null;
    }
};

fn snapshotRoom(room: *Room) messages.RoomDetailPayload {
    return .{
        .id = room.id,
        .name = room.name,
        .state = room.state,
        .host_id = room.host_user_id,
        .player_limit = room.config.player_limit,
        .players = room.players.items,
    };
}

fn tryRemovePlayer(
    service: *RoomService,
    room: *Room,
    user_id: i64,
) Error!void {
    const index = room.playerIndex(user_id) orelse return Error.NotInRoom;
    const removed = room.players.orderedRemove(index);
    service.allocator.free(@constCast(removed.username));

    if (removed.is_host) {
        if (room.players.items.len > 0) {
            room.players.items[0].is_host = true;
            room.host_user_id = room.players.items[0].user_id;
        } else {
            room.host_user_id = -1;
        }
    }
}

fn removeRoomLocked(self: *RoomService, room_id: u32) void {
    var removed = self.rooms.fetchRemove(room_id) orelse return;
    const name_slice = removed.value.name;
    _ = self.rooms_by_name.remove(name_slice);
    removed.value.deinit(self.allocator);
}

fn normalizeRoomName(name: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) {
        return Error.InvalidRoomName;
    }
    return trimmed;
}

fn ensurePlayerLimit(limit: u8) Error!void {
    if (limit < 2 or limit > 8) {
        return Error.InvalidPlayerLimit;
    }
}

const PayloadError = error{InvalidPayload};

const RoomPlayerSnapshot = struct {
    user_id: i64,
    is_host: bool,
    state: messages.RoomPlayerStatePayload,
};

const RoomDetailSnapshot = struct {
    allocator: std.mem.Allocator,
    id: u32,
    host_id: i64,
    state: messages.RoomStatePayload,
    players: []RoomPlayerSnapshot,

    fn deinit(self: *RoomDetailSnapshot) void {
        if (self.players.len > 0) {
            self.allocator.free(self.players);
        }
        self.* = undefined;
    }
};

// Removed expectUserResponseId and expectRoomDetailSnapshot functions as they are no longer needed with the new request method

test "room service room lifecycle" {
    const allocator = std.testing.allocator;

    var service = RoomService.init(allocator);
    defer service.deinit();

    const uid: i64 = 1;
    var created = try service.createRoom(uid, "Alice", .{
        .name = " Test Room ",
        .player_limit = 4,
    });
    try std.testing.expectEqual(@as(u32, 1), created.id);
    try std.testing.expectEqual(messages.RoomStatePayload.waiting, created.state);
    try std.testing.expectEqual(@as(usize, 1), created.players.len);
    try std.testing.expect(created.players[0].is_host);

    var list_view = try service.listRooms(allocator);
    try std.testing.expectEqual(@as(usize, 1), list_view.payload.rooms.len);
    list_view.deinit();

    var joined = try service.joinRoom(2, "Bob", .{ .room_id = created.id });
    try std.testing.expectEqual(@as(usize, 2), joined.players.len);

    joined = try service.setPrepared(2, .{ .prepared = true });
    try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, joined.players[1].state);

    created = try service.setPrepared(1, .{ .prepared = true });
    try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, created.players[0].state);

    created = try service.startGame(1);
    try std.testing.expectEqual(messages.RoomStatePayload.in_game, created.state);

    const leave_resp = try service.leaveRoom(2);
    try std.testing.expectEqual(created.id, leave_resp.room_id);

    service.handleDisconnect(uid);
}

test "room service reassigns host when original host leaves" {
    const allocator = std.testing.allocator;

    var service = RoomService.init(allocator);
    defer service.deinit();

    const host_id: i64 = 1;
    const detail = try service.createRoom(host_id, "Alice", .{
        .name = "Reassign Test",
        .player_limit = 4,
    });

    _ = try service.joinRoom(2, "Bob", .{ .room_id = detail.id });
    _ = try service.joinRoom(3, "Charlie", .{ .room_id = detail.id });

    const leave_resp = try service.leaveRoom(host_id);
    try std.testing.expectEqual(detail.id, leave_resp.room_id);

    const room_ptr = service.rooms.getPtr(detail.id) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), room_ptr.players.items.len);
    try std.testing.expectEqual(@as(i64, 2), room_ptr.host_user_id);
    try std.testing.expect(room_ptr.players.items[0].is_host);
    try std.testing.expectEqual(@as(i64, 2), room_ptr.players.items[0].user_id);
    try std.testing.expect(!room_ptr.players.items[1].is_host);
    try std.testing.expectEqual(@as(i64, 3), room_ptr.players.items[1].user_id);
}

test "integration: room lobby flow" {
    const port: u16 = 22031;
    try ws_test_client.withReadyClient(port, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const allocator = ctx.allocator;
            const host = &ctx.client;

            const host_payload = try host.request(allocator, 2000, "user_set_name", messages.UserSetNamePayload{ .nickname = "Alice" }, messages.UserInfoPayload);
            const host_id = host_payload.id;

            const created_payload = try host.request(allocator, 2000, "room_create", messages.RoomCreatePayload{
                .name = "Integration Room",
                .player_limit = 4,
            }, messages.RoomDetailPayload);
            const room_id = created_payload.id;
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

            const host_ready_payload = try host.request(allocator, 2000, "room_ready", messages.RoomReadyPayload{ .prepared = true }, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, host_ready_payload.players[0].state);

            const guest_ready_payload = try guest.request(allocator, 2000, "room_ready", messages.RoomReadyPayload{ .prepared = true }, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomPlayerStatePayload.prepared, guest_ready_payload.players[1].state);

            const started_payload = try host.request(allocator, 2000, "room_start", messages.RoomStartPayload{}, messages.RoomDetailPayload);
            try std.testing.expectEqual(messages.RoomStatePayload.in_game, started_payload.state);
        }
    }.run);
}
