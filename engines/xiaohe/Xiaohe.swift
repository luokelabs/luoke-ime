// 小鹤双拼：每个音节两个键。这里把按键还原成全拼音节。
let xiaoheFinals: [String: String] = [
    "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v", "ai": "d", "ei": "w", "ui": "v",
    "ao": "c", "ou": "z", "iu": "q", "ie": "p", "ue": "t", "ve": "t", "an": "j", "en": "f",
    "in": "b", "un": "y", "ang": "h", "eng": "g", "ing": "k", "ong": "s", "ia": "x", "ua": "x",
    "uo": "o", "iao": "n", "ian": "m", "uai": "k", "uan": "r", "iang": "l", "uang": "l", "iong": "s",
]
let xiaoheZero: [String: String] = [
    "a": "aa", "ai": "ai", "an": "an", "ang": "ah", "ao": "ao", "e": "ee", "ei": "ei", "en": "en",
    "eng": "eg", "er": "er", "o": "oo", "ou": "ou",
]
