extends RefCounted
class_name RandomNickname

static var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
static var _prefixes: Array[String] = [
	"快乐",
	"闪亮",
	"沉稳",
	"疾风",
	"神秘",
	"温柔",
	"勇敢",
	"灵巧",
	"晴空",
	"夜行",
]
static var _suffixes: Array[String] = [
	"小虎",
	"星梦",
	"旅人",
	"之光",
	"云雀",
	"木叶",
	"微风",
	"晨曦",
	"长歌",
	"远航",
]

static func init() -> void:
	_rng.randomize()

static func generate() -> String:
	if _prefixes.is_empty() or _suffixes.is_empty():
		return "玩家%d" % _rng.randi_range(1, 999)
	var prefix: String = _prefixes[_rng.randi_range(0, _prefixes.size() - 1)]
	var suffix: String = _suffixes[_rng.randi_range(0, _suffixes.size() - 1)]
	var nickname: String = prefix + suffix
	if _rng.randf() < 0.35:
		nickname += str(_rng.randi_range(1, 99))
	return nickname


