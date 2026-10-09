import Foundation

/// Formatting run inside a message whose control codes were removed (start in Characters).
public struct FmtSpan: Equatable {
    public var start: Int
    public var fg = -1          // mIRC colour index, -1 = default
    public var bg = -1
    public var bold = false
    public var underline = false
    public var italic = false
    var plain: Bool { fg < 0 && bg < 0 && !bold && !underline && !italic }
}

/// Text without mIRC control codes plus where the formatting changes.
public struct Formatted {
    public let text: String
    public let spans: [FmtSpan]
}

public enum IrcText {
    /// Strips colours/bold/underline/italic/reverse codes and records them as spans.
    public static func parse(_ raw: String) -> Formatted {
        let cs = Array(raw)
        var out = ""
        var count = 0
        var spans: [FmtSpan] = []
        var cur = FmtSpan(start: 0)
        var changed = false
        var i = 0
        func digits(_ max: Int) -> Int {
            var v = -1, n = 0
            while n < max, i < cs.count, let d = cs[i].wholeNumberValue, cs[i].isASCII {
                v = (v < 0 ? 0 : v) * 10 + d; i += 1; n += 1
            }
            return v
        }
        while i < cs.count {
            let c = cs[i]
            switch c {
            case "\u{03}":
                i += 1
                let fg = digits(2)
                if fg >= 0 {
                    var bg = cur.bg
                    if i + 1 < cs.count, cs[i] == ",", cs[i + 1].isASCII, cs[i + 1].isNumber {
                        i += 1
                        let b = digits(2)
                        bg = (0...15).contains(b) ? b : -1
                    }
                    cur.fg = (0...15).contains(fg) ? fg : -1
                    cur.bg = bg
                } else { cur.fg = -1; cur.bg = -1 }
                changed = true
            case "\u{04}":      // hex colours: dropped
                i += 1
                var n = 0
                while n < 6, i < cs.count, cs[i].isLetter || cs[i].isNumber { i += 1; n += 1 }
                if i + 1 < cs.count, cs[i] == "," {
                    i += 1; n = 0
                    while n < 6, i < cs.count, cs[i].isLetter || cs[i].isNumber { i += 1; n += 1 }
                }
            case "\u{02}": cur.bold.toggle(); changed = true; i += 1
            case "\u{1F}": cur.underline.toggle(); changed = true; i += 1
            case "\u{1D}": cur.italic.toggle(); changed = true; i += 1
            case "\u{0F}": cur = FmtSpan(start: 0); changed = true; i += 1
            default:
                if let a = c.asciiValue, a < 32, c != "\t" { i += 1; continue }   // reverse, monospace, others
                if changed {
                    var s = cur; s.start = count
                    if let l = spans.last, l.start == s.start { spans[spans.count - 1] = s } else { spans.append(s) }
                    changed = false
                }
                out.append(c); count += 1; i += 1
            }
        }
        if spans.count == 1, spans[0].plain { spans.removeAll() }
        return Formatted(text: out, spans: spans)
    }

    public static func strip(_ raw: String) -> String { parse(raw).text }

    private static func isNickChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "[]\\`_^{|}-".contains(c)
    }

    /// Case-insensitive whole-word match (nicks and highlight words).
    public static func containsWord(_ hay: String, _ needle: String) -> Bool {
        if needle.isEmpty { return false }
        var from = hay.startIndex
        while let r = hay.range(of: needle, options: .caseInsensitive, range: from..<hay.endIndex) {
            let left = r.lowerBound == hay.startIndex || !isNickChar(hay[hay.index(before: r.lowerBound)])
            let right = r.upperBound == hay.endIndex || !isNickChar(hay[r.upperBound])
            if left && right { return true }
            from = hay.index(after: r.lowerBound)
        }
        return false
    }

    /// Case-insensitive glob with * and ?
    public static func globMatch(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(s.lowercased())
        func m(_ pi0: Int, _ si0: Int) -> Bool {
            var pi = pi0, si = si0
            while pi < p.count {
                if p[pi] == "*" {
                    while pi < p.count, p[pi] == "*" { pi += 1 }
                    if pi == p.count { return true }
                    var k = si
                    while k <= t.count { if m(pi, k) { return true }; k += 1 }
                    return false
                }
                if si >= t.count { return false }
                if p[pi] != "?" && p[pi] != t[si] { return false }
                pi += 1; si += 1
            }
            return si == t.count
        }
        return m(0, 0)
    }

    /// URLs in a message (http/https), trailing punctuation removed, no duplicates.
    public static func urls(_ text: String, max: Int = 12) -> [String] {
        var out: [String] = []
        let cs = Array(text)
        var p = 0
        while out.count < max, p < cs.count {
            guard let start = find(cs, "http", from: p) else { break }
            let rest = String(cs[start..<min(cs.count, start + 8)])
            if !rest.hasPrefix("http://") && !rest.hasPrefix("https://") { p = start + 4; continue }
            var e = start
            while e < cs.count, !" \t\"'<>".contains(cs[e]) { e += 1 }
            while e > start, ".,;:!?)]".contains(cs[e - 1]) { e -= 1 }
            if (11...298).contains(e - start) {
                let u = String(cs[start..<e])
                if !out.contains(u) { out.append(u) }
            }
            p = e > start ? e : start + 4
        }
        return out
    }

    private static func find(_ cs: [Character], _ needle: String, from: Int) -> Int? {
        let n = Array(needle)
        guard cs.count >= n.count else { return nil }
        var i = from
        while i + n.count <= cs.count {
            if Array(cs[i..<i + n.count]) == n { return i }
            i += 1
        }
        return nil
    }

    public static func shouldSkipTranslation(_ t: String) -> Bool {
        let s = t.trimLeadingSpaces()
        if s.count < 2 { return true }
        if s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") { return true }
        if s.first == "/" || s.first == "!" { return true }
        return !s.contains { $0.isLetter || !$0.isASCII }
    }
}
