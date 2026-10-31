// 自然码双拼：每个音节两个键，声母和小鹤一样（zh ch sh 是 v i u），韵母的键位不同；零声母也和小鹤一样（aa、ah、ee、eg、oo，其余照拼）。
let ziranmaFinals: [String: String] = [
    "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v", "ai": "l", "ei": "z", "ui": "v",
    "ao": "k", "ou": "b", "iu": "q", "ie": "x", "ue": "t", "ve": "t", "an": "j", "en": "f",
    "in": "n", "un": "p", "ang": "h", "eng": "g", "ing": "y", "ong": "s", "ia": "w", "ua": "w",
    "uo": "o", "iao": "c", "ian": "m", "uai": "y", "uan": "r", "iang": "d", "uang": "d", "iong": "s",
]
