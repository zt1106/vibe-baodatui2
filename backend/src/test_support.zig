const std = @import("std");
const app = @import("app.zig");
const game_server = @import("game_server.zig");

pub fn withTempDir(action: fn() anyerror!void) !void {
    var original_dir = try std.fs.cwd().openDir(".", .{});
    defer original_dir.close();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_dir.setAsCwd() catch {};

    try action();
}

pub fn withTempDirContext(
    comptime Context: type,
    action: fn (*Context) anyerror!void,
    context: *Context,
) !void {
    var original_dir = try std.fs.cwd().openDir(".", .{});
    defer original_dir.close();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_dir.setAsCwd() catch {};

    try action(context);
}

pub const GameServerFixture = struct {
    allocator: std.mem.Allocator,
    game_app: *app.GameApp,
    instance: game_server.Instance,

    pub fn stop(self: *GameServerFixture) void {
        self.instance.stop();
    }

    pub fn deinit(self: *GameServerFixture) void {
        self.instance.deinit();
        self.game_app.deinit();
        self.allocator.destroy(self.game_app);
        self.* = undefined;
    }

    pub fn shutdown(self: *GameServerFixture) void {
        self.stop();
        self.deinit();
    }
};

pub fn spawnServer(allocator: std.mem.Allocator, config: game_server.Config) !GameServerFixture {
    const game_app = try allocator.create(app.GameApp);
    errdefer allocator.destroy(game_app);

    game_app.* = try app.GameApp.init(allocator);
    errdefer game_app.deinit();

    var instance = try game_server.start(game_app, allocator, config);
    errdefer {
        instance.stop();
        instance.deinit();
    }

    return .{
        .allocator = allocator,
        .game_app = game_app,
        .instance = instance,
    };
}
