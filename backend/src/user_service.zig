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

    pub fn ensureSchema(self: *Service) void {
        _ = self;
    }

    pub fn handleRegister(
        self: *Service,
        state: anytype,
        payload: messages.UserRegisterPayload,
    ) (Error || std.mem.Allocator.Error)!messages.UserResponsePayload {
        const username = try normalizeUsername(payload.username);
        const user = try self.createUser(username);
        try self.assignToConnection(state, username, user.id);
        return .{
            .id = user.id,
            .username = username,
        };
    }

    pub fn handleLogin(
        self: *Service,
        state: anytype,
        payload: messages.UserLoginPayload,
    ) (Error || std.mem.Allocator.Error)!messages.UserResponsePayload {
        const username = try normalizeUsername(payload.username);
        const user = try self.fetchUser(username);
        try self.assignToConnection(state, username, user.id);
        return .{
            .id = user.id,
            .username = username,
        };
    }

    pub fn handleGet(
        self: *Service,
        payload: messages.UserGetPayload,
    ) (Error || std.mem.Allocator.Error)!messages.UserResponsePayload {
        const username = try normalizeUsername(payload.username);
        const user = try self.fetchUser(username);
        return .{
            .id = user.id,
            .username = username,
        };
    }

    pub fn handleUpdate(
        self: *Service,
        state: anytype,
        payload: messages.UserUpdatePayload,
    ) (Error || std.mem.Allocator.Error)!messages.UserResponsePayload {
        const current = try normalizeUsername(payload.username);
        const desired = try normalizeUsername(payload.new_username);
        const user = try self.renameUser(current, desired);

        try self.updateConnectionIfMatches(state, current, desired, user.id);

        return .{
            .id = user.id,
            .username = desired,
        };
    }

    pub fn handleDelete(
        self: *Service,
        state: anytype,
        payload: messages.UserDeletePayload,
    ) (Error || std.mem.Allocator.Error)!messages.UserDeleteResponsePayload {
        const username = try normalizeUsername(payload.username);
        try self.deleteUser(username);
        self.clearConnectionIfMatches(state, username);
        return .{
            .username = username,
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

    fn fetchUser(
        self: *Service,
        username: []const u8,
    ) Error!User {
        const entry = self.users.get(username) orelse return Error.UserNotFound;
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

fn normalizeUsername(username: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, username, " \t\r\n");
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
    service.ensureSchema();

    const TestState = struct {
        user_name: ?[]u8 = null,
        user_id: ?i64 = null,
    };

    var register_state = TestState{};
    defer if (register_state.user_name) |name| allocator.free(name);

    const registered = try service.handleRegister(&register_state, .{ .username = " Alice " });
    try std.testing.expect(registered.id > 0);
    try std.testing.expectEqualStrings("Alice", registered.username);
    try std.testing.expect(register_state.user_id != null);
    try std.testing.expectEqual(registered.id, register_state.user_id.?);
    try std.testing.expectEqualStrings("Alice", register_state.user_name.?);

    var login_state = TestState{};
    defer if (login_state.user_name) |name| allocator.free(name);
    const logged_in = try service.handleLogin(&login_state, .{ .username = " Alice " });
    try std.testing.expectEqual(registered.id, logged_in.id);
    try std.testing.expectEqualStrings("Alice", logged_in.username);
    try std.testing.expectEqual(registered.id, login_state.user_id.?);
    try std.testing.expectEqualStrings("Alice", login_state.user_name.?);

    const fetched = try service.handleGet(.{ .username = "Alice" });
    try std.testing.expectEqual(registered.id, fetched.id);
    try std.testing.expectEqualStrings("Alice", fetched.username);

    const updated = try service.handleUpdate(&login_state, .{
        .username = "Alice",
        .new_username = "Alice Updated",
    });
    try std.testing.expectEqual(registered.id, updated.id);
    try std.testing.expectEqualStrings("Alice Updated", updated.username);
    try std.testing.expectEqualStrings("Alice Updated", login_state.user_name.?);

    const deleted = try service.handleDelete(&login_state, .{ .username = "Alice Updated" });
    try std.testing.expectEqualStrings("Alice Updated", deleted.username);
    try std.testing.expect(login_state.user_name == null);
    try std.testing.expect(login_state.user_id == null);

    try std.testing.expectError(Error.UserNotFound, service.handleGet(.{ .username = "Alice Updated" }));

    var invalid_state = TestState{};
    defer if (invalid_state.user_name) |name| allocator.free(name);
    try std.testing.expectError(Error.InvalidUsername, service.handleRegister(&invalid_state, .{ .username = "   " }));
}

test "integration: user register and login" {
    try ws_test_client.withReadyClient(22021, struct {
        fn run(ctx: *ws_test_client.IntegrationContext) !void {
            const allocator = ctx.allocator;

            const register_id = try ctx.client.sendRequest("user_register", messages.UserRegisterPayload{ .username = "Alice" });
            const user_id = try expectUserResponse(allocator, &ctx.client, register_id, "Alice");

            const login_request_id = try ctx.client.sendRequest("user_login", messages.UserLoginPayload{ .username = "Alice" });
            const login_id = try expectUserResponse(allocator, &ctx.client, login_request_id, "Alice");
            try std.testing.expectEqual(user_id, login_id);

            const get_request_id = try ctx.client.sendRequest("user_get", messages.UserGetPayload{ .username = "Alice" });
            const get_id = try expectUserResponse(allocator, &ctx.client, get_request_id, "Alice");
            try std.testing.expectEqual(user_id, get_id);
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
