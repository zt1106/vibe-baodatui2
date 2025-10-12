const std = @import("std");
const sqlite = @import("sqlite.zig");
const messages = @import("messages.zig");

pub const Error = error{
    UserExists,
    UserNotFound,
    InvalidUsername,
};

pub const User = struct {
    id: i64,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Database,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Database) Service {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn ensureSchema(self: *Service) !void {
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS users(
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    username TEXT NOT NULL UNIQUE
            \\);
        );
    }

    pub fn handleRegister(
        self: *Service,
        state: anytype,
        payload: messages.UserRegisterPayload,
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!messages.UserResponsePayload {
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
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!messages.UserResponsePayload {
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
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!messages.UserResponsePayload {
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
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!messages.UserResponsePayload {
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
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!messages.UserDeleteResponsePayload {
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
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!User {
        var stmt = try self.db.prepare(
            \\INSERT INTO users(username) VALUES (?1);
        );
        defer stmt.finalize();

        try stmt.bindText(1, username);
        stmt.stepExpectDone() catch |err| {
            if (err == sqlite.SqliteError.StepFailed and self.db.errCode() == sqlite.SQLITE_CONSTRAINT) {
                return Error.UserExists;
            }
            return err;
        };

        return User{ .id = self.db.lastInsertRowId() };
    }

    fn fetchUser(
        self: *Service,
        username: []const u8,
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!User {
        var stmt = try self.db.prepare(
            \\SELECT id FROM users WHERE username = ?1;
        );
        defer stmt.finalize();

        try stmt.bindText(1, username);

        return switch (try stmt.step()) {
            .row => User{ .id = stmt.columnInt(0) },
            .done => Error.UserNotFound,
        };
    }

    fn renameUser(
        self: *Service,
        current: []const u8,
        desired: []const u8,
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!User {
        var stmt = try self.db.prepare(
            \\UPDATE users
            \\SET username = ?2
            \\WHERE username = ?1
            \\RETURNING id;
        );
        defer stmt.finalize();

        try stmt.bindText(1, current);
        try stmt.bindText(2, desired);

        const result = stmt.step() catch |err| {
            if (err == sqlite.SqliteError.StepFailed and self.db.errCode() == sqlite.SQLITE_CONSTRAINT) {
                return Error.UserExists;
            }
            return err;
        };

        return switch (result) {
            .row => User{ .id = stmt.columnInt(0) },
            .done => Error.UserNotFound,
        };
    }

    fn deleteUser(
        self: *Service,
        username: []const u8,
    ) (Error || sqlite.SqliteError || std.mem.Allocator.Error)!void {
        var stmt = try self.db.prepare(
            \\DELETE FROM users WHERE username = ?1;
        );
        defer stmt.finalize();

        try stmt.bindText(1, username);
        try stmt.stepExpectDone();

        if (self.db.changes() == 0) {
            return Error.UserNotFound;
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

    var db = try sqlite.Database.open(allocator, ":memory:");
    defer db.close();

    var service = Service.init(allocator, &db);
    try service.ensureSchema();

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
