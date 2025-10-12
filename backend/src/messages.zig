const std = @import("std");

const mem = std.mem;
const AllocWriter = std.io.Writer.Allocating;
const JsonValue = std.json.Value;
const JsonParseResult = std.json.Parsed(JsonValue);

pub const Message = struct {
    parsed: JsonParseResult,
    type_name: []const u8,
    data: JsonValue,

    pub fn deinit(self: *Message) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn typeName(self: *const Message) []const u8 {
        return self.type_name;
    }

    pub fn payload(self: *const Message) JsonValue {
        return self.data;
    }

    pub fn payloadAs(self: *Message, comptime T: type) !T {
        return try std.json.parseFromValueLeaky(
            T,
            self.parsed.arena.allocator(),
            self.data,
            .{ .ignore_unknown_fields = true },
        );
    }
};

pub fn parseMessage(allocator: std.mem.Allocator, raw: []const u8) !Message {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, raw, .{});
    errdefer parsed.deinit();

    const root = parsed.value;
    const envelope = switch (root) {
        .object => |object| object,
        else => return error.InvalidEnvelope,
    };

    const type_value_ptr = envelope.get("type") orelse return error.MissingType;
    const type_name = switch (type_value_ptr) {
        .string => |name| name,
        else => return error.InvalidTypeField,
    };

    const payload_value = envelope.get("data") orelse JsonValue{ .null = {} };

    return Message{
        .parsed = parsed,
        .type_name = type_name,
        .data = payload_value,
    };
}

pub fn encodeMessage(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    payload: anytype,
) ![]u8 {
    var aw = AllocWriter.init(allocator);
    defer aw.deinit();

    var stringify = std.json.Stringify{
        .writer = &aw.writer,
        .options = .{ .whitespace = .minified },
    };

    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write(type_name);
    try stringify.objectField("data");

    if (@TypeOf(payload) == void) {
        try stringify.write(std.json.Value{ .null = {} });
    } else {
        try stringify.write(payload);
    }

    try stringify.endObject();

    return try aw.toOwnedSlice();
}

pub const JoinPayload = struct {
    name: []const u8,
};

pub const ChatPayload = struct {
    message: []const u8,
};

pub const MovePayload = struct {
    x: f32,
    y: f32,
};

pub const PingPayload = struct {};

pub const SystemPayload = struct {
    code: []const u8,
    message: []const u8,
};

test "parse message envelope" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"type":"join","data":{"name":"Alice"}}
    ;

    var msg = try parseMessage(allocator, raw);
    defer msg.deinit();

    try std.testing.expectEqualStrings("join", msg.typeName());
    const join = try msg.payloadAs(JoinPayload);
    try std.testing.expectEqualStrings("Alice", join.name);
}

test "encode message envelope" {
    const allocator = std.testing.allocator;
    const payload = SystemPayload{
        .code = "ok",
        .message = "ready",
    };

    const encoded = try encodeMessage(allocator, "system", payload);
    defer allocator.free(encoded);

    var decoded = try parseMessage(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqualStrings("system", decoded.typeName());
    const sys = try decoded.payloadAs(SystemPayload);
    try std.testing.expectEqualStrings(payload.message, sys.message);
}
