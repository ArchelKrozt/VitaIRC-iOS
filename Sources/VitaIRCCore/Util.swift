import Foundation

// MARK: - String helpers (the Kotlin port leans on these)

extension String {
    public func substringBefore(_ c: Character) -> String {
        if let i = firstIndex(of: c) { return String(self[..<i]) }
        return self
    }
    public func substringAfter(_ c: Character) -> String {
        if let i = firstIndex(of: c) { return String(self[index(after: i)...]) }
        return self
    }
    public func substringBeforeLast(_ c: Character) -> String {
        if let i = lastIndex(of: c) { return String(self[..<i]) }
        return self
    }
    public func substringAfterLast(_ c: Character, _ missing: String? = nil) -> String {
        if let i = lastIndex(of: c) { return String(self[index(after: i)...]) }
        return missing ?? self
    }
    /// Case-insensitive equality (IRC nicks and channels)
    public func eqi(_ o: String) -> Bool { caseInsensitiveCompare(o) == .orderedSame }
    public func containsi(_ o: String) -> Bool { range(of: o, options: .caseInsensitive) != nil }
    public func trimLeadingSpaces() -> String { String(drop(while: { $0 == " " })) }
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nonEmpty: String? { isEmpty ? nil : self }
    public func ifEmpty(_ d: String) -> String { isEmpty ? d : self }
    public func prefixChars(_ n: Int) -> String { String(prefix(n)) }
    public var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
    public func split(anyOf seps: String) -> [String] {
        split(omittingEmptySubsequences: false, whereSeparator: { seps.contains($0) }).map(String.init)
    }

    /// printf-style formatting for the shared Spanish/English texts:
    /// %s %d %ld %x with flags/width/precision, %f with precision, %%.
    public func f(_ args: Any...) -> String { Fmt.format(self, args) }
}

enum Fmt {
    static func format(_ fmt: String, _ args: [Any]) -> String {
        var out = ""
        var ai = 0
        let cs = Array(fmt)
        var i = 0
        while i < cs.count {
            let c = cs[i]
            if c != "%" { out.append(c); i += 1; continue }
            i += 1
            if i >= cs.count { break }
            if cs[i] == "%" { out.append("%"); i += 1; continue }
            var left = false, zero = false
            while i < cs.count, cs[i] == "-" || cs[i] == "0" {
                if cs[i] == "-" { left = true } else { zero = true }
                i += 1
            }
            var width = 0
            while i < cs.count, let d = cs[i].wholeNumberValue { width = width * 10 + d; i += 1 }
            var prec = -1
            if i < cs.count, cs[i] == "." {
                i += 1; prec = 0
                while i < cs.count, let d = cs[i].wholeNumberValue { prec = prec * 10 + d; i += 1 }
            }
            while i < cs.count, cs[i] == "l" { i += 1 }
            guard i < cs.count else { break }
            let conv = cs[i]; i += 1
            let arg: Any = ai < args.count ? args[ai] : ""
            ai += 1
            var s: String
            switch conv {
            case "d", "i":
                let v = (arg as? Int) ?? Int("\(arg)") ?? Int((arg as? Int64) ?? 0)
                s = String(abs(v))
                if zero && !left && width > 0 { while s.count < width - (v < 0 ? 1 : 0) { s = "0" + s } }
                if v < 0 { s = "-" + s }
            case "x", "X":
                let v = (arg as? Int) ?? 0
                s = String(v, radix: 16, uppercase: conv == "X")
                if zero && !left { while s.count < width { s = "0" + s } }
            case "f":
                let v = (arg as? Double) ?? Double("\(arg)") ?? 0
                s = String(format: "%.\(prec < 0 ? 6 : prec)f", v)
            default:   // s, @, c
                s = (arg as? String) ?? "\(arg)"
                if prec >= 0 { s = String(s.prefix(prec)) }
            }
            if s.count < width {
                let pad = String(repeating: " ", count: width - s.count)
                s = left ? s + pad : pad + s
            }
            out += s
        }
        return out
    }
}

// MARK: - Time (milliseconds since 1970, like the Android version)

public enum TimeUtil {
    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static let isoIn: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoInNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    public static func parseIso(_ s: String) -> Int64? {
        if let d = isoIn.date(from: s) ?? isoInNoFrac.date(from: s) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        // "2026-10-08T21:30Z" (no seconds)
        if s.count == 17, s.hasSuffix("Z"), let d = isoInNoFrac.date(from: String(s.dropLast()) + ":00Z") {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    public static func iso(_ ms: Int64) -> String { isoIn.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

    public static func hhmm(_ ms: Int64) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func ymd(_ ms: Int64) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    public static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}
