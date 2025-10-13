const std = @import("std");
const game_server = @import("game_server.zig");
const app = @import("app.zig");
const log = @import("log.zig");

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
