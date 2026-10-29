import Foundation

// 导出文件名模板。
//
// 为什么单独一个纯函数文件：文件名里混着用户输入（原文件名）、时间与
// 分隔符，任何一个没清干净都会变成「导出失败」或者更糟——导出到一半
// 才报路径非法。这类逻辑在 UI 里写死就再也测不到了，抽出来才钉得住
// 非法字符、缺 {ext}、空模板这些边界。
//
// 占位符（大小写敏感，全用花括号）：
//   {stem}  原文件名（不含扩展名），已被清理过非法字符
//   {date}  yyyyMMdd
//   {time}  HHmmss
//   {index} 三位序号，从 001 起（v1 只导单张，先占位给批量用）
//   {ext}   扩展名（不带点）
//
// 未知占位符原样保留：用户写错 {stme} 时，宁可在预览里看见它，也不要
// 被静默换成空串——那会让人以为自己写对了。

enum ExportNaming {
    static let defaultTemplate = "{stem}-imagecake.{ext}"

    /// 面板用来列提示，也用来判断模板里有没有不认识的占位符。
    static let knownTokens = ["{stem}", "{date}", "{time}", "{index}", "{ext}"]

    static func filename(template: String,
                         stem: String,
                         ext: String,
                         date: Date = Date(),
                         index: Int = 1,
                         timeZone: TimeZone = .current) -> String {
        let cleanedStem = sanitize(stem, fallback: "imagecake")
        let cleanedExt = sanitize(ext, fallback: "png")

        var text = template
        text = text.replacingOccurrences(of: "{stem}", with: cleanedStem)
        text = text.replacingOccurrences(of: "{date}", with: formatted(date, "yyyyMMdd", timeZone))
        text = text.replacingOccurrences(of: "{time}", with: formatted(date, "HHmmss", timeZone))
        text = text.replacingOccurrences(of: "{index}", with: String(format: "%03d", max(index, 1)))
        text = text.replacingOccurrences(of: "{ext}", with: cleanedExt)

        // 模板里没写 {ext} 就补上：扩展名缺失会让 fileExporter 猜内容类型。
        if !template.contains("{ext}") {
            text += "." + cleanedExt
        }

        let cleaned = sanitize(text, fallback: "")
        // 空模板会只剩 ".jpg"——那是个隐藏文件，不是用户想要的。
        if cleaned.isEmpty || cleaned.hasPrefix(".") {
            return "imagecake.\(cleanedExt)"
        }
        return cleaned
    }

    /// 模板里是否有不认识的占位符。面板据此给一句提醒，不阻断导出。
    static func unknownTokens(in template: String) -> [String] {
        // 先摘掉已知的，再从剩下里扫 {…}。
        var rest = template
        for token in knownTokens {
            rest = rest.replacingOccurrences(of: token, with: "")
        }
        var found: [String] = []
        var current = ""
        var inside = false
        for character in rest {
            if character == "{" {
                inside = true
                current = "{"
            } else if character == "}", inside {
                current += "}"
                if !found.contains(current) { found.append(current) }
                inside = false
                current = ""
            } else if inside {
                current.append(character)
            }
        }
        return found
    }

    // MARK: - 清理

    /// 去掉路径分隔符、Windows 保留字符与控制字符。
    ///
    /// 不用 `CharacterSet.illegalCharacters`：那套是按文件系统的，
    /// 而我们要的是「跨平台都不会出事的子集」——文件名最终可能经
    /// iCloud/Files 落到别的系统上。
    private static func sanitize(_ value: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = value.components(separatedBy: illegal).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func formatted(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        // en_US_POSIX：用户把系统改成佛历/民国纪年时，文件名不该跟着变。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
