const std = @import("std");

pub const SeatIndex = u8;

pub const TableError = error{
    InvalidSeatCount,
    InvalidSeat,
    SeatOccupied,
    SeatEmpty,
    TableFull,
    PlayerNotFound,
    NoPlayersSeated,
    TurnNotSet,
};

pub fn TableState(comptime PhaseType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        config: Config,
        seats: []?Player,
        seated_count: SeatIndex,
        dealer_seat: ?SeatIndex,
        current_turn: ?SeatIndex,
        phase_value: PhaseType,

        const Self = @This();

        pub const Player = struct {
            user_id: i64,
            seat: SeatIndex,
        };

        pub const Config = struct {
            seat_count: SeatIndex,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            config: Config,
            initial_phase: PhaseType,
        ) (std.mem.Allocator.Error || TableError)!Self {
            if (config.seat_count == 0) {
                return TableError.InvalidSeatCount;
            }

            const seats = try allocator.alloc(?Player, config.seat_count);
            errdefer allocator.free(seats);
            for (seats) |*slot| {
                slot.* = null;
            }

            return .{
                .allocator = allocator,
                .config = config,
                .seats = seats,
                .seated_count = 0,
                .dealer_seat = null,
                .current_turn = null,
                .phase_value = initial_phase,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.seats);
            self.* = undefined;
        }

        fn seatPtr(self: *Self, seat: SeatIndex) TableError!*?Player {
            if (seat >= self.config.seat_count) {
                return TableError.InvalidSeat;
            }
            return &self.seats[seat];
        }

        fn seatPtrConst(self: *const Self, seat: SeatIndex) TableError!*const ?Player {
            if (seat >= self.config.seat_count) {
                return TableError.InvalidSeat;
            }
            return &self.seats[seat];
        }

        pub fn seatPlayer(
            self: *Self,
            user_id: i64,
            seat: SeatIndex,
        ) TableError!Player {
            const slot = try self.seatPtr(seat);
            if (slot.* != null) {
                return TableError.SeatOccupied;
            }
            if (self.seated_count == self.config.seat_count) {
                return TableError.TableFull;
            }

            const player = Player{
                .user_id = user_id,
                .seat = seat,
            };
            slot.* = player;
            self.seated_count += 1;
            return player;
        }

        pub fn removePlayer(self: *Self, seat: SeatIndex) TableError!Player {
            const slot = try self.seatPtr(seat);
            const player = slot.* orelse return TableError.SeatEmpty;
            slot.* = null;
            self.seated_count -= 1;

            if (self.dealer_seat) |dealer_seat| {
                if (dealer_seat == seat) {
                    self.dealer_seat = null;
                }
            }
            if (self.current_turn) |turn_seat| {
                if (turn_seat == seat) {
                    self.current_turn = null;
                }
            }

            return player;
        }

        pub fn playerAt(self: *const Self, seat: SeatIndex) TableError!Player {
            const slot = try self.seatPtrConst(seat);
            return slot.* orelse TableError.SeatEmpty;
        }

        pub fn findPlayer(self: *const Self, user_id: i64) ?Player {
            for (self.seats) |slot| {
                if (slot) |player| {
                    if (player.user_id == user_id) {
                        return player;
                    }
                }
            }
            return null;
        }

        pub fn playerIndex(self: *const Self, user_id: i64) ?SeatIndex {
            for (self.seats, 0..) |slot, index| {
                if (slot) |player| {
                    if (player.user_id == user_id) {
                        return @intCast(index);
                    }
                }
            }
            return null;
        }

        pub fn seatCount(self: *const Self) SeatIndex {
            return self.config.seat_count;
        }

        pub fn seatedCount(self: *const Self) SeatIndex {
            return self.seated_count;
        }

        pub fn isFull(self: *const Self) bool {
            return self.seated_count == self.config.seat_count;
        }

        pub fn phase(self: *const Self) PhaseType {
            return self.phase_value;
        }

        pub fn updatePhase(self: *Self, next_phase: PhaseType) void {
            self.phase_value = next_phase;
        }

        pub fn dealer(self: *const Self) ?SeatIndex {
            return self.dealer_seat;
        }

        pub fn setDealer(self: *Self, seat: SeatIndex) TableError!void {
            _ = try self.playerAt(seat);
            self.dealer_seat = seat;
        }

        pub fn clearDealer(self: *Self) void {
            self.dealer_seat = null;
        }

        pub fn currentTurn(self: *const Self) ?SeatIndex {
            return self.current_turn;
        }

        pub fn setCurrentTurn(self: *Self, seat: SeatIndex) TableError!void {
            _ = try self.playerAt(seat);
            self.current_turn = seat;
        }

        pub fn clearCurrentTurn(self: *Self) void {
            self.current_turn = null;
        }

        pub fn firstOccupiedSeat(self: *const Self) TableError!SeatIndex {
            if (self.seated_count == 0) {
                return TableError.NoPlayersSeated;
            }
            for (self.seats, 0..) |slot, index| {
                if (slot != null) {
                    return @intCast(index);
                }
            }
            return TableError.NoPlayersSeated;
        }

        pub fn seatAfter(self: *const Self, start: SeatIndex) TableError!SeatIndex {
            if (self.seated_count == 0) {
                return TableError.NoPlayersSeated;
            }
            if (start >= self.config.seat_count) {
                return TableError.InvalidSeat;
            }

            const seat_count_usize = @as(usize, self.config.seat_count);
            const start_usize = @as(usize, start);
            var index: usize = (start_usize + 1) % seat_count_usize;
            while (index != start_usize) {
                if (self.seats[index] != null) {
                    return @intCast(index);
                }
                index = (index + 1) % seat_count_usize;
            }

            if (self.seats[start_usize] != null) {
                return start;
            }
            return self.firstOccupiedSeat();
        }

        pub fn occupiedCount(self: *const Self) SeatIndex {
            return self.seated_count;
        }
    };
}

test "TableState init and seating players" {
    const allocator = std.testing.allocator;
    const Phase = enum { waiting, dealing };
    var table = try TableState(Phase).init(
        allocator,
        .{ .seat_count = 4 },
        .waiting,
    );
    defer table.deinit();

    try std.testing.expectEqual(@as(SeatIndex, 0), table.seatedCount());
    _ = try table.seatPlayer(11, 0);
    _ = try table.seatPlayer(12, 1);
    try std.testing.expectEqual(@as(SeatIndex, 2), table.seatedCount());

    try std.testing.expectError(TableError.SeatOccupied, table.seatPlayer(13, 1));
    try std.testing.expectError(TableError.InvalidSeat, table.seatPlayer(13, 4));

    const player = try table.playerAt(0);
    try std.testing.expectEqual(@as(i64, 11), player.user_id);
    try std.testing.expectEqual(@as(SeatIndex, 0), player.seat);

    _ = try table.removePlayer(0);
    try std.testing.expectEqual(@as(SeatIndex, 1), table.seatedCount());
    try std.testing.expectError(TableError.SeatEmpty, table.removePlayer(0));
}

test "TableState dealer rotation and seatAfter" {
    const allocator = std.testing.allocator;
    const Phase = enum { lobby, game };
    var table = try TableState(Phase).init(
        allocator,
        .{ .seat_count = 3 },
        .lobby,
    );
    defer table.deinit();

    _ = try table.seatPlayer(1, 0);
    _ = try table.seatPlayer(2, 2);

    const first = try table.firstOccupiedSeat();
    try std.testing.expectEqual(@as(SeatIndex, 0), first);

    try table.setDealer(first);
    const next = try table.seatAfter(first);
    try std.testing.expectEqual(@as(SeatIndex, 2), next);

    try table.setCurrentTurn(next);
    try std.testing.expectEqual(@as(?SeatIndex, 2), table.currentTurn());

    const wrap = try table.seatAfter(next);
    try std.testing.expectEqual(@as(SeatIndex, 0), wrap);
}

test "TableState invalid initialization" {
    const allocator = std.testing.allocator;
    const Phase = enum { state };
    try std.testing.expectError(
        TableError.InvalidSeatCount,
        TableState(Phase).init(allocator, .{ .seat_count = 0 }, .state),
    );
}
