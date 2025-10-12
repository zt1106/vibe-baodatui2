const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const log = std.log.scoped(.sqlite);

pub const SqliteError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    UnexpectedResult,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) (SqliteError || std.mem.Allocator.Error)!Database {
        const z_path = try dupZ(allocator, path);
        defer allocator.free(z_path);

        var db_handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(z_path.ptr, &db_handle, flags, null);
        if (rc != c.SQLITE_OK or db_handle == null) {
            if (db_handle) |handle| {
                const message = errorMessage(handle);
                log.err("sqlite open failed ({d}): {s}", .{ rc, message });
                _ = c.sqlite3_close(handle);
            } else {
                log.err("sqlite open failed ({d}) with null handle", .{rc});
            }
            return error.OpenFailed;
        }

        return .{
            .allocator = allocator,
            .handle = db_handle.?,
        };
    }

    pub fn close(self: *Database) void {
        const rc = c.sqlite3_close(self.handle);
        if (rc != c.SQLITE_OK) {
            const message = errorMessage(self.handle);
            log.warn("sqlite close warning ({d}): {s}", .{ rc, message });
        }
        self.handle = undefined;
    }

    pub fn exec(self: *Database, sql: []const u8) (SqliteError || std.mem.Allocator.Error)!void {
        const z_sql = try dupZ(self.allocator, sql);
        defer self.allocator.free(z_sql);

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, z_sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg_ptr| {
                const message = std.mem.sliceTo(msg_ptr, 0);
                log.err("sqlite exec failed ({d}): {s}", .{ rc, message });
                c.sqlite3_free(msg_ptr);
            } else {
                const message = errorMessage(self.handle);
                log.err("sqlite exec failed ({d}): {s}", .{ rc, message });
            }
            return error.ExecFailed;
        }
    }

    pub fn prepare(self: *Database, sql: []const u8) (SqliteError || std.mem.Allocator.Error)!Statement {
        const z_sql = try dupZ(self.allocator, sql);
        defer self.allocator.free(z_sql);

        var stmt_handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, z_sql.ptr, -1, &stmt_handle, null);
        if (rc != c.SQLITE_OK or stmt_handle == null) {
            const message = errorMessage(self.handle);
            log.err("sqlite prepare failed ({d}): {s}", .{ rc, message });
            return error.PrepareFailed;
        }

        return Statement{
            .db = self,
            .handle = stmt_handle.?,
        };
    }
};

pub const Statement = struct {
    db: *Database,
    handle: *c.sqlite3_stmt,

    pub fn bindText(self: *Statement, index: c_int, value: []const u8) SqliteError!void {
        const ptr: [*c]const u8 = if (value.len > 0) @ptrCast(value.ptr) else null;
        const rc = c.sqlite3_bind_text(self.handle, index, ptr, @as(c_int, @intCast(value.len)), null);
        if (rc != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) SqliteError!void {
        const rc = c.sqlite3_bind_int64(self.handle, index, value);
        if (rc != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn step(self: *Statement) SqliteError!StepResult {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => StepResult.row,
            c.SQLITE_DONE => StepResult.done,
            else => {
                const message = errorMessage(self.db.handle);
                log.err("sqlite step failed ({d}): {s}", .{ rc, message });
                return error.StepFailed;
            },
        };
    }

    pub fn stepExpectDone(self: *Statement) SqliteError!void {
        const result = try self.step();
        if (result != .done) {
            return error.UnexpectedResult;
        }
    }

    pub fn reset(self: *Statement) SqliteError!void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return error.StepFailed;
    }

    pub fn finalize(self: *Statement) void {
        const rc = c.sqlite3_finalize(self.handle);
        if (rc != c.SQLITE_OK) {
            const message = errorMessage(self.db.handle);
            log.warn("sqlite finalize warning ({d}): {s}", .{ rc, message });
        }
        self.handle = undefined;
    }

    pub fn columnInt(self: *Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, column);
    }
};

pub const StepResult = enum { row, done };

fn dupZ(allocator: std.mem.Allocator, slice: []const u8) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, slice.len, 0);
    std.mem.copyForwards(u8, buf, slice);
    return buf;
}

fn errorMessage(handle: *c.sqlite3) []const u8 {
    const msg_ptr = c.sqlite3_errmsg(handle);
    return std.mem.sliceTo(msg_ptr, 0);
}

test "sqlite database basic operations" {
    const allocator = std.testing.allocator;
    const path = "test.db";

    // Ensure a clean slate for the database file.
    if (std.fs.cwd().deleteFile(path)) |_| {} else |_| {}

    var db = try Database.open(allocator, path);
    defer db.close();

    try db.exec(
        \\CREATE TABLE items(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  qty INTEGER NOT NULL
        \\);
    );

    {
        var insert_stmt = try db.prepare(
            \\INSERT INTO items(id, name, qty) VALUES (?1, ?2, ?3);
        );
        defer insert_stmt.finalize();

        try insert_stmt.bindInt(1, 1);
        try insert_stmt.bindText(2, "potion");
        try insert_stmt.bindInt(3, 5);
        try insert_stmt.stepExpectDone();
    }

    {
        var query_stmt = try db.prepare(
            \\SELECT qty FROM items WHERE name = ?1;
        );
        defer query_stmt.finalize();

        try query_stmt.bindText(1, "potion");
        try std.testing.expectEqual(StepResult.row, try query_stmt.step());
        try std.testing.expectEqual(@as(i64, 5), query_stmt.columnInt(0));
        try std.testing.expectEqual(StepResult.done, try query_stmt.step());
    }

    {
        var upsert_stmt = try db.prepare(
            \\INSERT INTO items(id, name, qty)
            \\VALUES (?1, ?2, ?3)
            \\ON CONFLICT(id) DO UPDATE SET qty = qty + excluded.qty;
        );
        defer upsert_stmt.finalize();

        try upsert_stmt.bindInt(1, 1);
        try upsert_stmt.bindText(2, "potion");
        try upsert_stmt.bindInt(3, 2);
        try upsert_stmt.stepExpectDone();
    }

    {
        var verify_stmt = try db.prepare(
            \\SELECT qty FROM items WHERE id = ?1;
        );
        defer verify_stmt.finalize();

        try verify_stmt.bindInt(1, 1);
        try std.testing.expectEqual(StepResult.row, try verify_stmt.step());
        try std.testing.expectEqual(@as(i64, 7), verify_stmt.columnInt(0));
        try std.testing.expectEqual(StepResult.done, try verify_stmt.step());
    }

    // Clean up the temporary database file to avoid polluting the workspace.
    if (std.fs.cwd().deleteFile(path)) |_| {} else |_| {}
}
