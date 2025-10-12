const std = @import("std");
const game_server = @import("game_server.zig");
const app = @import("app.zig");

pub const std_options = std.Options{
    .log_level = std.log.default_level,
    .logFn = customLog,
};

fn customLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = levelColor(level);
    const scope_name = if (scope == .default) "default" else @tagName(scope);
    const level_name = comptime level.asText();

    var buf: [128]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();

    nosuspend stderr.print(
        "{s}[{s}] ({s}) ",
        .{ color, level_name, scope_name },
    ) catch return;
    nosuspend stderr.print(format, args) catch return;
    nosuspend stderr.print("\x1b[0m\n", .{}) catch return;
}

fn levelColor(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[36m",
        .debug => "\x1b[90m",
    };
}

const log = std.log.scoped(.ws_server);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            log.warn("allocator reported leaked memory", .{});
        }
    }

    const allocator = gpa.allocator();

    var application = try app.GameApp.init(allocator);
    defer application.deinit();

    log.info("booting game server", .{});

    try game_server.run(&application, allocator, .{});
}
