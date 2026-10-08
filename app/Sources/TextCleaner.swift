// 認識結果を貼り付けられる形に整える
import Foundation

enum TextCleaner {
    private static let ja = "[\\u3000-\\u30ff\\u3400-\\u9fff\\uff00-\\uffef]"

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = sub(t, "(?<=\(ja))[ \\t]+|[ \\t]+(?=\(ja))", "")       // 英字・数字と日本語の間の半角スペース
        t = sub(t, "\\s*\\n\\s*", "\n")
        t = sub(t, "(?<=\(ja))\\s+(?=\(ja))", "")                 // 日本語間の余計な空白・改行
        t = sub(t, "\\s*\\n\\s*", " ")                            // 残った改行は空白に (貼り付けに改行を混ぜない)
        // 日本語の後の半角 ?! は全角に (「!!」「!?」のように続く場合もすべて)
        while t.range(of: "(?<=\(ja)|[！？])[?!]", options: .regularExpression) != nil {
            t = sub(t, "(?<=\(ja)|[！？])\\?", "？")
            t = sub(t, "(?<=\(ja)|[！？])!", "！")
        }
        t = sub(t, "(?<=[！？])[ \\t]+(?=\(ja))", "")
        t = sub(t, "。{2,}", "。").trimmingCharacters(in: .whitespacesAndNewlines)
        // 「。」だけ、などは貼り付けない
        if t.range(of: "[\\p{L}\\p{N}]", options: .regularExpression) == nil { return "" }
        return t
    }
}
