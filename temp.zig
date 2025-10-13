const std = @import("std");
const messages = @import("backend/src/messages.zig");

fn parse(raw: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();
    var frame = try messages.parseFrame(allocator, raw);
    defer frame.deinit();
}

pub fn main() !void {
    const raw = "\xEF\xBB\xBF{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"user_set_name\",\"params\":{\"nickname\":\"Test\"}}";
    parse(raw) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
    };
}
