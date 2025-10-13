const std = @import("std");
const game_server = @import("game_server.zig");
const app = @import("app.zig");

inline fn customLog(
    comptime level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const color = levelColor(level);
    const level_name = comptime level.asText();
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();
    if (std.debug.getSelfDebugInfo() catch null) |info| {
        const addr = @returnAddress();
        std.debug.printSourceAtAddress(info, stderr, addr, .no_color) catch {};
    }
    nosuspend stderr.print(
        "{s}[{s}] ",
        .{ color, level_name },
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

pub fn log_info(comptime format: []const u8, args: anytype) void {
    customLog(.info, format, args);
}

pub fn log_warn(comptime format: []const u8, args: anytype) void {
    customLog(.warn, format, args);
}

pub fn log_err(comptime format: []const u8, args: anytype) void {
    customLog(.err, format, args);
}

pub fn log_debug(comptime format: []const u8, args: anytype) void {
    customLog(.debug, format, args);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            log_warn("allocator reported leaked memory", .{});
        }
    }

    const allocator = gpa.allocator();

    var application = try app.GameApp.init(allocator);
    defer application.deinit();

    log_info("booting game server", .{});

    try game_server.run(&application, allocator, .{});
}
