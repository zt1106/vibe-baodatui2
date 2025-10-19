extends RefCounted
class_name MockData

static func build_mock_rooms() -> Array:
	return [
		{
			"id": 101,
			"name": "休闲牌桌",
			"state": "waiting",
			"player_count": 2,
			"player_limit": 6,
			"config": {"player_limit": 6},
			"host_id": 5001,
			"players": [
				{"user_id": 5001, "username": "DealerDan", "state": "prepared", "is_host": true},
				{"user_id": 5002, "username": "LuckyLuna", "state": "not_prepared", "is_host": false},
			],
		},
		{
			"id": 202,
			"name": "高额牌桌",
			"state": "in_game",
			"player_count": 4,
			"player_limit": 6,
			"config": {"player_limit": 6},
			"host_id": 6001,
			"players": [
				{"user_id": 6001, "username": "AceAaron", "state": "prepared", "is_host": true},
				{"user_id": 6002, "username": "BluffBella", "state": "prepared", "is_host": false},
				{"user_id": 6003, "username": "ChipCharlie", "state": "prepared", "is_host": false},
				{"user_id": 6004, "username": "RiverRiley", "state": "prepared", "is_host": false},
			],
		},
		{
			"id": 303,
			"name": "夜猫子牌桌",
			"state": "waiting",
			"player_count": 3,
			"player_limit": 5,
			"config": {"player_limit": 5},
			"host_id": 7001,
			"players": [
				{"user_id": 7001, "username": "MidnightMia", "state": "prepared", "is_host": true},
				{"user_id": 7002, "username": "SleeplessSam", "state": "not_prepared", "is_host": false},
				{"user_id": 7003, "username": "CoffeeKai", "state": "prepared", "is_host": false},
			],
		},
	]

