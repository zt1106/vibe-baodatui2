const std = @import("std");

const meta = std.meta;
const AllocWriter = std.io.Writer.Allocating;
const JsonValue = std.json.Value;
const JsonParseResult = std.json.Parsed(JsonValue);

pub const JsonRpcVersion = "2.0";

pub const FrameError = error{InvalidFrameKind};

pub const RpcErrorCodes = struct {
    pub const ParseError: i64 = -32700;
    pub const InvalidRequest: i64 = -32600;
    pub const MethodNotFound: i64 = -32601;
    pub const InvalidParams: i64 = -32602;
    pub const InternalError: i64 = -32603;
    pub const ServerError: i64 = -32000; // implementation-defined range -32000..-32099
};

pub fn mapParseFrameError(err: anyerror) struct { code: i64, message: []const u8 } {
    return switch (err) {
        error.InvalidEnvelope, error.MissingJsonRpcVersion, error.InvalidJsonRpcVersion, error.InvalidMethodField, error.InvalidErrorField, error.MissingIdField, error.InvalidFrameStructure, error.InvalidIdField => .{ .code = RpcErrorCodes.InvalidRequest, .message = "Invalid Request" },
        else => .{ .code = RpcErrorCodes.ParseError, .message = "Parse error" },
    };
}

pub const Id = union(enum) {
    integer: i64,
    string: []const u8,
    null: void,

    pub fn fromInt(value: i64) Id {
        return .{ .integer = value };
    }

    pub fn fromString(value: []const u8) Id {
        return .{ .string = value };
    }

    pub fn isNull(self: Id) bool {
        return self == .null;
    }
};

pub const NullId = Id{ .null = {} };

pub const Payload = union(enum) {
    call: Call,
    response: Response,
    rpc_error: Error,
};

pub const PayloadTag = meta.Tag(Payload);

pub const Call = struct {
    method: []const u8,
    params: JsonValue,
    id: ?Id,
    arena: std.mem.Allocator,

    pub fn methodName(self: *const Call) []const u8 {
        return self.method;
    }

    pub fn idValue(self: *const Call) ?Id {
        return self.id;
    }

    pub fn isNotification(self: *const Call) bool {
        return self.id == null;
    }

    pub fn paramsValue(self: *const Call) JsonValue {
        return self.params;
    }

    pub fn paramsAs(self: *Call, comptime T: type) !T {
        return try std.json.parseFromValueLeaky(
            T,
            self.arena,
            self.params,
            .{ .ignore_unknown_fields = true },
        );
    }
};

pub const Response = struct {
    id: Id,
    result: JsonValue,
    arena: std.mem.Allocator,

    pub fn idValue(self: *const Response) Id {
        return self.id;
    }

    pub fn resultValue(self: *const Response) JsonValue {
        return self.result;
    }

    pub fn resultAs(self: *Response, comptime T: type) !T {
        return try std.json.parseFromValueLeaky(
            T,
            self.arena,
            self.result,
            .{ .ignore_unknown_fields = true },
        );
    }
};

pub const Error = struct {
    id: ?Id,
    code: i64,
    message: []const u8,
    data: ?JsonValue,
    arena: std.mem.Allocator,

    pub fn idValue(self: *const Error) ?Id {
        return self.id;
    }

    pub fn messageValue(self: *const Error) []const u8 {
        return self.message;
    }

    pub fn codeValue(self: *const Error) i64 {
        return self.code;
    }

    pub fn dataValue(self: *const Error) ?JsonValue {
        return self.data;
    }
};

pub const Frame = struct {
    parsed: JsonParseResult,
    payload: Payload,

    pub fn deinit(self: *Frame) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn kind(self: *const Frame) PayloadTag {
        return meta.activeTag(self.payload);
    }

    pub fn call(self: *Frame) !*Call {
        return switch (self.payload) {
            .call => |*c| c,
            else => FrameError.InvalidFrameKind,
        };
    }

    pub fn response(self: *Frame) !*Response {
        return switch (self.payload) {
            .response => |*r| r,
            else => FrameError.InvalidFrameKind,
        };
    }

    pub fn rpcError(self: *Frame) !*Error {
        return switch (self.payload) {
            .rpc_error => |*e| e,
            else => FrameError.InvalidFrameKind,
        };
    }
};

pub fn parseFrame(allocator: std.mem.Allocator, raw: []const u8) !Frame {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, raw, .{});
    errdefer parsed.deinit();

    const root = parsed.value;
    const envelope = switch (root) {
        .object => |object| object,
        else => return error.InvalidEnvelope,
    };

    const version_ptr = envelope.get("jsonrpc") orelse return error.MissingJsonRpcVersion;
    const version = switch (version_ptr) {
        .string => |value| value,
        else => return error.InvalidJsonRpcVersion,
    };

    if (!std.mem.eql(u8, version, JsonRpcVersion)) {
        return error.InvalidJsonRpcVersion;
    }

    if (envelope.get("method")) |method_ptr| {
        const method = switch (method_ptr) {
            .string => |value| value,
            else => return error.InvalidMethodField,
        };

        const params = envelope.get("params") orelse JsonValue{ .null = {} };
        var id_opt: ?Id = null;
        if (envelope.get("id")) |id_ptr| {
            id_opt = try parseId(id_ptr);
        }

        return Frame{
            .parsed = parsed,
            .payload = .{ .call = Call{
                .method = method,
                .params = params,
                .id = id_opt,
                .arena = parsed.arena.allocator(),
            } },
        };
    }

    if (envelope.get("error")) |error_ptr| {
        const error_obj = switch (error_ptr) {
            .object => |object| object,
            else => return error.InvalidErrorField,
        };

        const code_value = error_obj.get("code") orelse return error.InvalidErrorField;
        const code = switch (code_value) {
            .integer => |value| value,
            else => return error.InvalidErrorField,
        };

        const message_value = error_obj.get("message") orelse return error.InvalidErrorField;
        const message = switch (message_value) {
            .string => |value| value,
            else => return error.InvalidErrorField,
        };

        var id_opt: ?Id = null;
        if (envelope.get("id")) |id_ptr| {
            id_opt = try parseId(id_ptr);
        }

        const data = error_obj.get("data");

        return Frame{
            .parsed = parsed,
            .payload = .{ .rpc_error = Error{
                .id = id_opt,
                .code = code,
                .message = message,
                .data = data,
                .arena = parsed.arena.allocator(),
            } },
        };
    }

    if (envelope.get("result")) |result_ptr| {
        const id_ptr = envelope.get("id") orelse return error.MissingIdField;
        const id_value = try parseId(id_ptr);

        return Frame{
            .parsed = parsed,
            .payload = .{ .response = Response{
                .id = id_value,
                .result = result_ptr,
                .arena = parsed.arena.allocator(),
            } },
        };
    }

    return error.InvalidFrameStructure;
}

fn parseId(value: JsonValue) !Id {
    return switch (value) {
        .integer => |int_value| Id{ .integer = int_value },
        .string => |string_value| Id{ .string = string_value },
        .null => NullId,
        else => error.InvalidIdField,
    };
}

fn writeId(stringify: *std.json.Stringify, id: Id) !void {
    switch (id) {
        .integer => |value| try stringify.write(value),
        .string => |value| try stringify.write(value),
        .null => try stringify.write(JsonValue{ .null = {} }),
    }
}

fn encodeEnvelope(allocator: std.mem.Allocator, writer: anytype) ![]u8 {
    var aw = AllocWriter.init(allocator);
    defer aw.deinit();

    var stringify = std.json.Stringify{
        .writer = &aw.writer,
        .options = .{ .whitespace = .minified },
    };

    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write(JsonRpcVersion);
    try writer.write(&stringify);
    try stringify.endObject();

    return try aw.toOwnedSlice();
}

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
    id: Id,
) ![]u8 {
    const Writer = struct {
        id: Id,
        method: []const u8,
        params: @TypeOf(params),
        fn write(self: @This(), stringify: *std.json.Stringify) !void {
            try stringify.objectField("id");
            try writeId(stringify, self.id);
            try stringify.objectField("method");
            try stringify.write(self.method);
            try stringify.objectField("params");
            try stringify.write(self.params);
        }
    };

    return encodeEnvelope(allocator, Writer{
        .id = id,
        .method = method,
        .params = params,
    });
}

pub fn encodeNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
) ![]u8 {
    const Writer = struct {
        method: []const u8,
        params: @TypeOf(params),
        fn write(self: @This(), stringify: *std.json.Stringify) !void {
            try stringify.objectField("method");
            try stringify.write(self.method);
            try stringify.objectField("params");
            try stringify.write(self.params);
        }
    };

    return encodeEnvelope(allocator, Writer{
        .method = method,
        .params = params,
    });
}

pub fn encodeResponse(
    allocator: std.mem.Allocator,
    id: Id,
    result: anytype,
) ![]u8 {
    const Writer = struct {
        id: Id,
        result: @TypeOf(result),
        fn write(self: @This(), stringify: *std.json.Stringify) !void {
            try stringify.objectField("id");
            try writeId(stringify, self.id);
            try stringify.objectField("result");
            try stringify.write(self.result);
        }
    };

    return encodeEnvelope(allocator, Writer{
        .id = id,
        .result = result,
    });
}

pub fn encodeResponseNull(
    allocator: std.mem.Allocator,
    id: Id,
) ![]u8 {
    return encodeResponse(allocator, id, JsonValue{ .null = {} });
}

pub fn encodeError(
    allocator: std.mem.Allocator,
    id: ?Id,
    code: i64,
    message: []const u8,
) ![]u8 {
    const Writer = struct {
        id: ?Id,
        code: i64,
        message: []const u8,
        fn write(self: @This(), stringify: *std.json.Stringify) !void {
            try stringify.objectField("id");
            if (self.id) |value| {
                try writeId(stringify, value);
            } else {
                try stringify.write(JsonValue{ .null = {} });
            }
            try stringify.objectField("error");
            try stringify.beginObject();
            try stringify.objectField("code");
            try stringify.write(self.code);
            try stringify.objectField("message");
            try stringify.write(self.message);
            try stringify.endObject();
        }
    };

    return encodeEnvelope(allocator, Writer{
        .id = id,
        .code = code,
        .message = message,
    });
}

pub fn formatPrettyJson(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, raw, .{});
    defer parsed.deinit();
    return try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })},
    );
}

pub fn idsEqual(a: Id, b: Id) bool {
    if (meta.activeTag(a) != meta.activeTag(b)) return false;
    return switch (a) {
        .integer => |value| switch (b) {
            .integer => |other| value == other,
            else => unreachable,
        },
        .string => |value| switch (b) {
            .string => |other| std.mem.eql(u8, value, other),
            else => unreachable,
        },
        .null => true,
    };
}

pub fn idToInt(id: Id) ?i64 {
    return switch (id) {
        .integer => |value| value,
        .string => null,
        .null => null,
    };
}

pub const EmptyParams = struct {};

pub const SystemPayload = struct {
    code: []const u8,
    message: []const u8,
};

pub const PingPayload = struct {};

pub const RoomStatePayload = enum {
    waiting,
    in_game,
};

pub const RoomPlayerStatePayload = enum {
    not_prepared,
    prepared,
};

pub const RoomSummaryPayload = struct {
    id: u32,
    name: []const u8,
    state: RoomStatePayload,
    player_count: u8,
    player_limit: u8,
};

pub const RoomPlayerPayload = struct {
    user_id: i64,
    username: []const u8,
    state: RoomPlayerStatePayload,
    is_host: bool,
};

pub const RoomDetailPayload = struct {
    id: u32,
    name: []const u8,
    state: RoomStatePayload,
    host_id: i64,
    player_limit: u8,
    players: []const RoomPlayerPayload,
};

pub const RoomListRequestPayload = struct {};

pub const RoomListResponsePayload = struct {
    rooms: []const RoomSummaryPayload,
};

pub const RoomCreatePayload = struct {
    name: []const u8,
    player_limit: u8 = 4,
};

pub const RoomJoinPayload = struct {
    room_id: u32,
};

pub const RoomLeavePayload = struct {};

pub const RoomLeaveResponsePayload = struct {
    room_id: u32,
};

pub const RoomReadyPayload = struct {
    prepared: bool,
};

pub const RoomStartPayload = struct {};

pub const UserSetNamePayload = struct {
    nickname: []const u8,
};

pub const UserInfoPayload = struct {
    id: i64,
    username: []const u8,
};

test "parse json-rpc call" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":42,"method":"ping","params":{}}
    ;

    var frame = try parseFrame(allocator, raw);
    defer frame.deinit();

    try std.testing.expectEqual(PayloadTag.call, frame.kind());

    const call = try frame.call();
    try std.testing.expect(!call.isNotification());
    try std.testing.expectEqualStrings("ping", call.methodName());

    const payload = try call.paramsAs(PingPayload);
    _ = payload;
    const id = call.idValue().?;
    try std.testing.expectEqual(@as(i64, 42), idToInt(id).?);
}

test "encode json-rpc response" {
    const allocator = std.testing.allocator;
    const result = SystemPayload{
        .code = "ok",
        .message = "ready",
    };

    const encoded = try encodeResponse(allocator, Id.fromInt(7), result);
    defer allocator.free(encoded);

    var frame = try parseFrame(allocator, encoded);
    defer frame.deinit();

    try std.testing.expectEqual(PayloadTag.response, frame.kind());

    const response = try frame.response();
    try std.testing.expect(idsEqual(response.idValue(), Id.fromInt(7)));
    const decoded = try response.resultAs(SystemPayload);
    try std.testing.expectEqualStrings(result.message, decoded.message);
}
