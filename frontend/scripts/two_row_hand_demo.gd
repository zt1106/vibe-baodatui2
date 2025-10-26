extends Control

const CARDS_PER_ROW := 6

@onready var card_manager: CardManager = $CardManager
@onready var card_factory: CardFactory = $CardManager/MyCardFactory
@onready var deck: Pile = $CardManager/Deck
@onready var hand_top: Hand = $CardManager/PlayerHandTop
@onready var hand_bottom: Hand = $CardManager/PlayerHandBottom


func _ready() -> void:
	resized.connect(_on_size_changed)
	_configure_hand(hand_top)
	_configure_hand(hand_bottom)
	_on_size_changed()
	_reset_deck()
	_deal_initial_cards()


func _configure_hand(hand: Hand) -> void:
	# Force the hand layout into a straight line and expand to fit the viewport width.
	hand.hand_rotation_curve = null
	hand.hand_vertical_curve = null
	hand.card_face_up = true
	hand.max_hand_size = 12


func _on_size_changed() -> void:
	var screen_width: float = maxf(size.x, 1.0)
	var desired_spread: float = maxf(screen_width * 0.8, 800.0)
	hand_top.max_hand_spread = desired_spread
	hand_bottom.max_hand_spread = desired_spread


func _reset_deck() -> void:
	var list := _get_randomized_card_list()
	deck.clear_cards()
	for card_name in list:
		card_factory.create_card(card_name, deck)


func _deal_initial_cards() -> void:
	for i in range(CARDS_PER_ROW):
		hand_top.move_cards(deck.get_top_cards(1), -1, false)
	for i in range(CARDS_PER_ROW):
		hand_bottom.move_cards(deck.get_top_cards(1), -1, false)


func _get_randomized_card_list() -> Array:
	var suits := ["club", "spade", "diamond", "heart"]
	var values := ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]
	var card_list: Array[String] = []
	for suit in suits:
		for value in values:
			card_list.append("%s_%s" % [suit, value])
	card_list.shuffle()
	return card_list
