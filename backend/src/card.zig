const std = @import("std");

pub const Suit = enum {
    hearts,
    diamonds,
    clubs,
    spades,
};

pub const Rank = enum(u8) {
    ace = 1,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,
    ten,
    jack,
    queen,
    king,
};

pub const JokerType = enum {
    red,
    black,
};

pub const Card = union(enum) {
    standard: struct {
        suit: Suit,
        rank: Rank,
    },
    joker: JokerType,
};

test "Card creation" {
    const card = Card{ .standard = .{ .suit = .hearts, .rank = .ace } };
    try std.testing.expectEqual(card.standard.suit, Suit.hearts);
    try std.testing.expectEqual(card.standard.rank, Rank.ace);
}

test "Card equality" {
    const card1 = Card{ .standard = .{ .suit = .spades, .rank = .king } };
    const card2 = Card{ .standard = .{ .suit = .spades, .rank = .king } };
    const card3 = Card{ .standard = .{ .suit = .hearts, .rank = .king } };
    try std.testing.expectEqual(card1, card2);
    try std.testing.expect(!std.meta.eql(card1, card3));
}

test "Suit and Rank enums" {
    try std.testing.expectEqual(std.meta.fields(Suit).len, 4);
    try std.testing.expectEqual(std.meta.fields(Rank).len, 13);
}

test "Rank enum values" {
    try std.testing.expectEqual(@intFromEnum(Rank.ace), 1);
    try std.testing.expectEqual(@intFromEnum(Rank.two), 2);
    try std.testing.expectEqual(@intFromEnum(Rank.ten), 10);
    try std.testing.expectEqual(@intFromEnum(Rank.jack), 11);
    try std.testing.expectEqual(@intFromEnum(Rank.queen), 12);
    try std.testing.expectEqual(@intFromEnum(Rank.king), 13);
}

test "Rank from u8" {
    try std.testing.expectEqual(@as(Rank, @enumFromInt(1)), Rank.ace);
    try std.testing.expectEqual(@as(Rank, @enumFromInt(13)), Rank.king);
}

test "Joker cards" {
    const red_joker = Card{ .joker = .red };
    const black_joker = Card{ .joker = .black };
    try std.testing.expectEqual(red_joker.joker, JokerType.red);
    try std.testing.expectEqual(black_joker.joker, JokerType.black);
    try std.testing.expect(!std.meta.eql(red_joker, black_joker));
}
