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

pub const Card = struct {
    suit: Suit,
    rank: Rank,
};

test "Card creation" {
    const card = Card{
        .suit = .hearts,
        .rank = .ace,
    };
    try std.testing.expectEqual(card.suit, Suit.hearts);
    try std.testing.expectEqual(card.rank, Rank.ace);
}

test "Card equality" {
    const card1 = Card{
        .suit = .spades,
        .rank = .king,
    };
    const card2 = Card{
        .suit = .spades,
        .rank = .king,
    };
    const card3 = Card{
        .suit = .hearts,
        .rank = .king,
    };
    try std.testing.expectEqual(card1, card2);
    try std.testing.expect(!std.meta.eql(card1, card3));
}

test "Suit and Rank enums" {
    try std.testing.expectEqual(@typeInfo(Suit).Enum.fields.len, 4);
    try std.testing.expectEqual(@typeInfo(Rank).Enum.fields.len, 13);
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
