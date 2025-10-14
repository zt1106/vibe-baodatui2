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

/// Get the card corresponding to an index by taking index % 54
pub fn getCard(index: u16) card.Card {
    return StaticDeck[index % 54];
}

/// Create a game deck with a specified number of 54-card decks
pub fn createGameDeck(allocator: std.mem.Allocator, num_decks: usize) !std.ArrayList(u16) {
    var deck = try std.ArrayList(u16).initCapacity(allocator, num_decks * 54);
    errdefer deck.deinit(allocator);

    for (0..num_decks * 54) |i| {
        deck.appendAssumeCapacity(@intCast(i));
    }

    return deck;
}

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

test "getCard function" {
    try std.testing.expectEqual(getCard(0), StaticDeck[0]);
    try std.testing.expectEqual(getCard(53), StaticDeck[53]);
    try std.testing.expectEqual(getCard(54), StaticDeck[0]); // Wraps around
    try std.testing.expectEqual(getCard(107), StaticDeck[53]); // 107 % 54 = 53
}

test "createGameDeck function" {
    var single_deck = try createGameDeck(std.testing.allocator, 1);
    defer single_deck.deinit(std.testing.allocator);
    try std.testing.expectEqual(single_deck.items.len, 54);
    try std.testing.expectEqual(single_deck.items[0], 0);
    try std.testing.expectEqual(single_deck.items[53], 53);

    var double_deck = try createGameDeck(std.testing.allocator, 2);
    defer double_deck.deinit(std.testing.allocator);
    try std.testing.expectEqual(double_deck.items.len, 108);
    try std.testing.expectEqual(double_deck.items[0], 0);
    try std.testing.expectEqual(double_deck.items[53], 53);
    try std.testing.expectEqual(double_deck.items[54], 54); // Second deck starts
    try std.testing.expectEqual(double_deck.items[107], 107);
}

test "getCard with u16" {
    try std.testing.expectEqual(getCard(0), StaticDeck[0]);
    try std.testing.expectEqual(getCard(53), StaticDeck[53]);
    try std.testing.expectEqual(getCard(54), StaticDeck[0]); // Wraps around
    try std.testing.expectEqual(getCard(65535), StaticDeck[65535 % 54]); // Max u16 wraps correctly
}
