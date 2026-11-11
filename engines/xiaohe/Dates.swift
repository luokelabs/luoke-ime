import Foundation

/// 打出「日期」「时间」「星期」「农历」这几个词时，把这会儿的值也给出来，排在这个词后面（搜狗、苹果拼音也是这样）。
/// 雾凇用的是专门的触发码（全拼 rq、xq、nl，双拼 date、week、lunar），双拼里 xq、nl 是 xiu、niang，所以不照搬，
/// 三个方案都按打出来的词触发。
enum Dates {
    static var now: () -> Date = Date.init

    static func values(for word: String) -> [String] {
        let d = now()
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
        let (y, m, day) = (c.year!, c.month!, c.day!)
        switch word {
        case "日期":
            return [String(format: "%04d-%02d-%02d", y, m, day), "\(y)年\(m)月\(day)日"]
        case "时间":
            return [String(format: "%02d:%02d", c.hour!, c.minute!)]
        case "星期":
            return ["星期" + ["日", "一", "二", "三", "四", "五", "六"][c.weekday! - 1]]
        case "农历":
            return [lunar(d)]
        default:
            return []
        }
    }

    static let words: Set<String> = ["日期", "时间", "星期", "农历"]

    /// 农历：干支年、生肖、月、日，比如「丙午马年九月二十六」（和雾凇的写法一样）。
    static func lunar(_ d: Date) -> String {
        let cal = Calendar(identifier: .chinese)
        let c = cal.dateComponents([.year, .month, .day], from: d)
        let leap = cal.dateComponents([.month], from: d).isLeapMonth == true
        let i = (c.year! - 1) % 60
        let stems = Array("甲乙丙丁戊己庚辛壬癸"), branches = Array("子丑寅卯辰巳午未申酉戌亥"), zodiac = Array("鼠牛虎兔龙蛇马羊猴鸡狗猪")
        let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        let digits = Array("一二三四五六七八九十")
        let n = c.day!
        let dayText: String
        switch n {
        case 1...10: dayText = "初" + String(digits[n - 1])
        case 11...19: dayText = "十" + String(digits[n - 11])
        case 20: dayText = "二十"
        case 21...29: dayText = "二十" + String(digits[n - 21])
        default: dayText = "三十"
        }
        return "\(stems[i % 10])\(branches[i % 12])\(zodiac[i % 12])年\(leap ? "闰" : "")\(months[c.month! - 1])月\(dayText)"
    }
}
