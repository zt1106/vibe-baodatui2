const std = @import("std");
const card = @import("card.zig");

pub const StaticDeck = blk: {
    @setEvalBranchQuota(10000);
    var cards: [54]card.Card = undefined;
    var i: usize = 0;

    // Generate standard cards
    for (std.meta.fields(card.Suit)) |suit_field| {
        const suit = @field(card.Suit, suit_field.name);
        for (std.meta.fields(card.Rank)) |rank_field| {
            const rank = @field(card.Rank, rank_field.name);
            cards[i] = .{ .standard = .{ .suit = suit, .rank = rank } };
            i += 1;
        }
    }

    // Add jokers
    cards[i] = .{ .joker = .red };
    i += 1;
    cards[i] = .{ .joker = .black };

    break :blk cards;
};

test "Deck length" {
    try std.testing.expectEqual(StaticDeck.len, 54);
}

test "Deck contents" {
    // Check first card
    try std.testing.expectEqual(StaticDeck[0].standard.suit, card.Suit.hearts);
    try std.testing.expectEqual(StaticDeck[0].standard.rank, card.Rank.ace);
    // Check last standard card
    try std.testing.expectEqual(StaticDeck[51].standard.suit, card.Suit.spades);
    try std.testing.expectEqual(StaticDeck[51].standard.rank, card.Rank.king);
    // Check red joker
    try std.testing.expectEqual(StaticDeck[52].joker, card.JokerType.red);
    // Check black joker
    try std.testing.expectEqual(StaticDeck[53].joker, card.JokerType.black);
}
