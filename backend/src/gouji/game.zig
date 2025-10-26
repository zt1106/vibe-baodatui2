const std = @import("std");
const deck = @import("../deck.zig");
const table = @import("../game_table.zig");

pub const Phase = enum {
    seating,
    dealing,
    tossing,
    challenging,
    playing,
    finished,
};

pub const Config = struct {
    seat_count: table.SeatIndex = 6,
    min_players: table.SeatIndex = 6,
    deck_count: usize = 2,
};

pub const Error = table.TableError || std.mem.Allocator.Error || error{
    InvalidConfig,
    NotEnoughPlayers,
    InvalidPhaseTransition,
    MissingTossWinner,
};

const TableState = table.TableState(Phase);

pub const Game = struct {
    allocator: std.mem.Allocator,
    config: Config,
    table_state: TableState,
    deck: std.ArrayList(u16),
    discard: std.ArrayListUnmanaged(u16) = .{},
    round_index: u32 = 0,
    toss_owner: ?table.SeatIndex = null,
    challenge_owner: ?table.SeatIndex = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Game {
        if (config.min_players == 0 or config.min_players > config.seat_count) {
            return error.InvalidConfig;
        }

        var table_state = try TableState.init(
            allocator,
            .{ .seat_count = config.seat_count },
            .seating,
        );
        errdefer table_state.deinit();

        var deck_list = try deck.createGameDeck(allocator, config.deck_count);
        errdefer deck_list.deinit(allocator);

        return .{
            .allocator = allocator,
            .config = config,
            .table_state = table_state,
            .deck = deck_list,
        };
    }

    pub fn deinit(self: *Game) void {
        self.deck.deinit(self.allocator);
        self.discard.deinit(self.allocator);
        self.table_state.deinit();
        self.* = undefined;
    }

    pub fn phase(self: *const Game) Phase {
        return self.table_state.phase();
    }

    pub fn roundIndex(self: *const Game) u32 {
        return self.round_index;
    }

    pub fn tossOwner(self: *const Game) ?table.SeatIndex {
        return self.toss_owner;
    }

    pub fn challengeOwner(self: *const Game) ?table.SeatIndex {
        return self.challenge_owner;
    }

    pub fn tableState(self: *Game) *TableState {
        return &self.table_state;
    }

    pub fn seatPlayer(self: *Game, user_id: i64, seat: table.SeatIndex) Error!void {
        try self.ensurePhase(.seating);
        _ = try self.table_state.seatPlayer(user_id, seat);
    }

    pub fn removePlayer(self: *Game, seat: table.SeatIndex) Error!void {
        try self.ensurePhase(.seating);
        _ = try self.table_state.removePlayer(seat);
    }

    pub fn startRound(self: *Game) Error!void {
        try self.ensurePhase(.seating);
        if (self.table_state.seatedCount() < self.config.min_players) {
            return error.NotEnoughPlayers;
        }

        const next_dealer = try self.nextDealerSeat();
        try self.table_state.setDealer(next_dealer);
        try self.table_state.setCurrentTurn(next_dealer);

        self.round_index += 1;
        self.toss_owner = null;
        self.challenge_owner = null;
        self.discard.clearRetainingCapacity();

        self.table_state.updatePhase(.dealing);
    }

    pub fn finishDealing(self: *Game) Error!void {
        try self.ensurePhase(.dealing);
        self.table_state.updatePhase(.tossing);
    }

    pub fn resolveToss(self: *Game, winner: table.SeatIndex) Error!void {
        try self.ensurePhase(.tossing);
        _ = try self.table_state.playerAt(winner);
        self.toss_owner = winner;
        self.table_state.updatePhase(.challenging);
    }

    pub fn resolveChallenge(self: *Game, challenger: ?table.SeatIndex) Error!void {
        try self.ensurePhase(.challenging);
        if (self.toss_owner == null) {
            return error.MissingTossWinner;
        }

        if (challenger) |seat| {
            _ = try self.table_state.playerAt(seat);
        }

        self.challenge_owner = challenger;

        const lead = challenger orelse self.toss_owner.?;
        try self.table_state.setCurrentTurn(lead);
        self.table_state.updatePhase(.playing);
    }

    pub fn finishRound(self: *Game) Error!void {
        try self.ensurePhase(.playing);
        self.table_state.updatePhase(.finished);
        self.table_state.clearCurrentTurn();
    }

    pub fn resetForNextRound(self: *Game) Error!void {
        try self.ensurePhase(.finished);

        const new_deck = try deck.createGameDeck(self.allocator, self.config.deck_count);
        self.deck.deinit(self.allocator);
        self.deck = new_deck;

        self.discard.clearRetainingCapacity();
        self.toss_owner = null;
        self.challenge_owner = null;
        self.table_state.clearCurrentTurn();
        self.table_state.updatePhase(.seating);
    }

    fn ensurePhase(self: *const Game, expected: Phase) Error!void {
        if (self.table_state.phase() != expected) {
            return error.InvalidPhaseTransition;
        }
    }

    fn nextDealerSeat(self: *Game) Error!table.SeatIndex {
        if (self.table_state.dealer()) |current| {
            return self.table_state.seatAfter(current);
        }
        return self.table_state.firstOccupiedSeat();
    }
};

test "GoujiGame round flow transitions" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, .{});
    defer game.deinit();

    const seat_total = game.config.seat_count;
    var seat: table.SeatIndex = 0;
    while (seat < seat_total) : (seat += 1) {
        try game.seatPlayer(@intCast(seat + 100), seat);
    }

    try game.startRound();
    try std.testing.expectEqual(Phase.dealing, game.phase());
    try std.testing.expectEqual(@as(u32, 1), game.roundIndex());
    const dealer = game.tableState().dealer() orelse unreachable;
    try std.testing.expectEqual(@as(table.SeatIndex, 0), dealer);

    try game.finishDealing();
    try std.testing.expectEqual(Phase.tossing, game.phase());

    try game.resolveToss(2);
    try std.testing.expectEqual(Phase.challenging, game.phase());
    try std.testing.expectEqual(@as(?table.SeatIndex, 2), game.tossOwner());

    try game.resolveChallenge(null);
    try std.testing.expectEqual(Phase.playing, game.phase());
    try std.testing.expectEqual(@as(?table.SeatIndex, 2), game.tableState().currentTurn());

    try game.finishRound();
    try std.testing.expectEqual(Phase.finished, game.phase());

    try game.resetForNextRound();
    try std.testing.expectEqual(Phase.seating, game.phase());
    try std.testing.expectEqual(@as(?table.SeatIndex, null), game.tossOwner());

    try game.startRound();
    try std.testing.expectEqual(Phase.dealing, game.phase());
    try std.testing.expectEqual(@as(u32, 2), game.roundIndex());
    const next_dealer = game.tableState().dealer() orelse unreachable;
    try std.testing.expectEqual(@as(table.SeatIndex, 1), next_dealer);
}

test "GoujiGame requires enough players to start" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, .{ .min_players = 4, .seat_count = 6 });
    defer game.deinit();

    try game.seatPlayer(1, 0);
    try game.seatPlayer(2, 1);
    try game.seatPlayer(3, 2);

    try std.testing.expectError(error.NotEnoughPlayers, game.startRound());
}

test "GoujiGame challenge requires toss winner" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, .{});
    defer game.deinit();

    const seat_total = game.config.seat_count;
    var seat: table.SeatIndex = 0;
    while (seat < seat_total) : (seat += 1) {
        try game.seatPlayer(@intCast(seat + 10), seat);
    }

    try game.startRound();
    try game.finishDealing();

    game.tableState().updatePhase(.challenging);
    game.toss_owner = null;

    try std.testing.expectError(error.MissingTossWinner, game.resolveChallenge(null));
}
