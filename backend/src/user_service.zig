const std = @import("std");
const messages = @import("messages.zig");
const ws_test_client = @import("ws_test_client.zig");

pub const Error = error{
    UserExists,
    UserNotFound,
    InvalidUsername,
};

pub const User = struct {
    id: i64,
};

const Entry = struct {
    id: i64,
    name_storage: []u8,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    users: std.StringHashMap(Entry),
    next_id: i64,

    pub fn init(allocator: std.mem.Allocator) Service {
        return .{
            .allocator = allocator,
            .users = std.StringHashMap(Entry).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Service) void {
        var it = self.users.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.name_storage);
        }
        self.users.deinit();
    }

    pub fn handleSetName(
        self: *Service,
        state: anytype,
        payload: messages.UserSetNamePayload,
    ) (Error || std.mem.Allocator.Error)!messages.UserInfoPayload {
        comptime ensureStatePointer(@TypeOf(state));

        const nickname = try normalizeNickname(payload.nickname);

        if (state.*.user_id) |id| {
            const current_ptr = state.*.user_name;
            if (current_ptr) |current| {
                if (std.mem.eql(u8, current, nickname)) {
                    return .{ .id = id, .username = current };
                }
                const user = try self.renameUser(current, nickname);
                try self.updateConnectionIfMatches(state, current, nickname, user.id);
                return .{
                    .id = user.id,
                    .username = state.*.user_name.?,
                };
            }

            // Missing cached name; treat as fresh allocation after clearing the association.
            self.removeUserById(id);
            state.*.user_id = null;
        }

        if (state.*.user_name) |dangling| {
            self.allocator.free(dangling);
            state.*.user_name = null;
        }

        const user = try self.createUser(nickname);
        try self.assignToConnection(state, nickname, user.id);
        return .{
            .id = user.id,
            .username = state.*.user_name.?,
        };
    }

    fn createUser(
        self: *Service,
        username: []const u8,
    ) (Error || std.mem.Allocator.Error)!User {
        if (self.users.contains(username)) {
            return Error.UserExists;
        }

        const name_copy = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(name_copy);

        const entry = Entry{
            .id = self.next_id,
            .name_storage = name_copy,
        };

        try self.users.put(name_copy, entry);
        self.next_id += 1;
        return User{ .id = entry.id };
    }

    fn renameUser(
        self: *Service,
        current: []const u8,
        desired: []const u8,
    ) (Error || std.mem.Allocator.Error)!User {
        if (self.users.contains(desired)) return Error.UserExists;

        const removed = self.users.fetchRemove(current) orelse return Error.UserNotFound;
        const new_copy = try self.allocator.dupe(u8, desired);
        errdefer self.allocator.free(new_copy);
        self.allocator.free(removed.value.name_storage);

        const entry = Entry{ .id = removed.value.id, .name_storage = new_copy };
        try self.users.put(new_copy, entry);
        return User{ .id = entry.id };
    }

    fn deleteUser(
        self: *Service,
        username: []const u8,
    ) Error!void {
        const removed = self.users.fetchRemove(username) orelse return Error.UserNotFound;
        self.allocator.free(removed.value.name_storage);
    }

    fn removeUserById(self: *Service, id: i64) void {
        var iterator = self.users.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.id == id) {
                const key_slice = entry.key_ptr.*;
                const removed = self.users.fetchRemove(key_slice) orelse return;
                self.allocator.free(removed.value.name_storage);
                return;
            }
        }
    }

    fn assignToConnection(
        self: *Service,
        state: anytype,
        username: []const u8,
        id: i64,
    ) std.mem.Allocator.Error!void {
        comptime ensureStatePointer(@TypeOf(state));

        if (state.*.user_name) |existing| {
            if (std.mem.eql(u8, existing, username)) {
                state.*.user_id = id;
                return;
            }
            self.allocator.free(existing);
            state.*.user_name = null;
        }

        const copy = try self.allocator.dupe(u8, username);
        state.*.user_name = copy;
        state.*.user_id = id;
    }

    fn updateConnectionIfMatches(
        self: *Service,
        state: anytype,
        current: []const u8,
        desired: []const u8,
        id: i64,
    ) std.mem.Allocator.Error!void {
        comptime ensureStatePointer(@TypeOf(state));

        if (state.*.user_name) |existing| {
            if (!std.mem.eql(u8, existing, current)) {
                return;
            }
            self.allocator.free(existing);
            state.*.user_name = null;
        } else {
            return;
        }

        const copy = try self.allocator.dupe(u8, desired);
        state.*.user_name = copy;
        state.*.user_id = id;
    }

    fn clearConnectionIfMatches(
        self: *Service,
        state: anytype,
        username: []const u8,
    ) void {
        comptime ensureStatePointer(@TypeOf(state));

        if (state.*.user_name) |existing| {
            if (std.mem.eql(u8, existing, username)) {
                self.allocator.free(existing);
                state.*.user_name = null;
                state.*.user_id = null;
            }
        }
    }
};

fn normalizeNickname(raw: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        return Error.InvalidUsername;
    }
    return trimmed;
}

fn ensureStatePointer(comptime T: type) void {
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |ptr| {
            const child = ptr.child;
            if (!@hasField(child, "user_name") or !@hasField(child, "user_id")) {
                @compileError("state must provide user_name and user_id fields");
            }
        },
        else => @compileError("state must be a pointer type"),
    }
}

test "user service lifecycle operations" {
    const allocator = std.testing.allocator;

    var service = Service.init(allocator);
    defer service.deinit();

    const TestState = struct {
        user_name: ?[]u8 = null,
        user_id: ?i64 = null,
    };

    var first_state = TestState{};
    defer if (first_state.user_name) |name| allocator.free(name);

    const first = try service.handleSetName(&first_state, .{ .nickname = " Alice " });
    try std.testing.expect(first.id > 0);
    try std.testing.expectEqualStrings("Alice", first.username);
    try std.testing.expectEqual(first.id, first_state.user_id.?);
    try std.testing.expectEqualStrings("Alice", first_state.user_name.?);

    const unchanged = try service.handleSetName(&first_state, .{ .nickname = "Alice" });
    try std.testing.expectEqual(first.id, unchanged.id);
    try std.testing.expectEqualStrings("Alice", unchanged.username);

    const renamed = try service.handleSetName(&first_state, .{ .nickname = "Alice Updated" });
    try std.testing.expectEqual(first.id, renamed.id);
    try std.testing.expectEqualStrings("Alice Updated", renamed.username);
    try std.testing.expectEqualStrings("Alice Updated", first_state.user_name.?);

    var second_state = TestState{};
    defer if (second_state.user_name) |name| allocator.free(name);
    try std.testing.expectError(Error.UserExists, service.handleSetName(&second_state, .{ .nickname = "Alice Updated" }));

    const second = try service.handleSetName(&second_state, .{ .nickname = "Bob" });
    try std.testing.expect(second.id > 0);
    try std.testing.expectEqualStrings("Bob", second.username);

    var invalid_state = TestState{};
    defer if (invalid_state.user_name) |name| allocator.free(name);
    try std.testing.expectError(Error.InvalidUsername, service.handleSetName(&invalid_state, .{ .nickname = "   " }));
}

test "integration: user set name and rename" {
    try ws_test_client.withReadyClient(22021, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const allocator = ctx.allocator;

            const set_id = try ctx.client.sendRequest("user_set_name", messages.UserSetNamePayload{ .nickname = "Alice" });
            const user_id = try expectUserResponse(allocator, &ctx.client, set_id, "Alice");

            const rename_id = try ctx.client.sendRequest("user_set_name", messages.UserSetNamePayload{ .nickname = "Alice Updated" });
            const renamed_id = try expectUserResponse(allocator, &ctx.client, rename_id, "Alice Updated");
            try std.testing.expectEqual(user_id, renamed_id);
        }
    }.run);
}

fn expectUserResponse(
    allocator: std.mem.Allocator,
    client: *ws_test_client.TestClient,
    request_id: messages.Id,
    expected_username: []const u8,
) (ws_test_client.ClientError || PayloadError || anyerror)!i64 {
    var frame = try client.expectResponse(allocator, 2000, request_id);
    defer frame.deinit();

    const response = switch (frame.kind()) {
        .response => try frame.response(),
        else => return PayloadError.InvalidPayload,
    };

    const payload_value = response.resultValue();
    const payload_obj = switch (payload_value) {
        .object => |obj| obj,
        else => return PayloadError.InvalidPayload,
    };

    const username_value = payload_obj.get("username") orelse return PayloadError.InvalidPayload;
    const username_str = switch (username_value) {
        .string => |s| s,
        else => return PayloadError.InvalidPayload,
    };
    try std.testing.expectEqualStrings(expected_username, username_str);

    const id_value = payload_obj.get("id") orelse return PayloadError.InvalidPayload;
    const id_int = switch (id_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return PayloadError.InvalidPayload,
    };
    try std.testing.expect(id_int > 0);

    return id_int;
}
const PayloadError = error{InvalidPayload};
