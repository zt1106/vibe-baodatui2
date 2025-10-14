const std = @import("std");

inline fn levelColor(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[36m",
        .debug => "\x1b[90m",
    };
}

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

    nosuspend stderr.print("{s}[{s}] ", .{ color, level_name }) catch return;
    nosuspend stderr.print(format, args) catch return;
    nosuspend stderr.print("\x1b[0m\n", .{}) catch return;
}

pub fn info(comptime format: []const u8, args: anytype) void {
    customLog(.info, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    customLog(.warn, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    customLog(.err, format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    customLog(.debug, format, args);
}
