import Foundation

/// Chat logs and the open-window session, in the same files as VitaIRC for PS Vita and Android:
/// logs/<server>/<channel>.log with "date\ttime\ttype\tself\tnick\ttext\tms\tmsgid" lines.
public enum History {
    static let loadLines = 150
    private static let tailBytes = 48 * 1024
    private static let maxLogBytes = 512 * 1024

    /// Set while a log is replayed into a window: no logging, no unread counters, no translations.
    nonisolated(unsafe) static var loading = false
    nonisolated(unsafe) private static var restoring = false

    private static func safeName(_ s: String) -> String {
        var b = ""
        for c in s {
            if (c.isASCII && (c.isLetter || c.isNumber)) || "#-_.".contains(c) { b.append(Character(c.lowercased())) } else { b.append("_") }
        }
        return b.isEmpty ? "_" : b
    }

    private static func serverDir(_ s: Server) -> URL {
        Config.dir.appendingPathComponent("logs").appendingPathComponent(safeName(s.cfg.host.ifEmpty("server")))
    }
    private static func logFile(_ s: Server, _ c: Chan) -> URL { serverDir(s).appendingPathComponent(safeName(c.name) + ".log") }

    private static func loggable(_ t: MsgType) -> Bool { [.msg, .action, .notice, .topic, .kick, .nick].contains(t) }

    static func log(_ s: Server, _ c: Chan, _ m: Msg) {
        if loading || c.type == .status || !loggable(m.type) { return }
        if c.log == nil {
            let f = logFile(s, c)
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: f.path) { FileManager.default.createFile(atPath: f.path, contents: nil) }
            c.log = try? FileHandle(forWritingTo: f)
            _ = try? c.log?.seekToEnd()
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: TimeUtil.date(m.ts))
        let text = m.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let line = "%04d-%02d-%02d\t%s\t%d\t%d\t%s\t%s\t%d\t%s\n".f(comps.year ?? 0, comps.month ?? 0, comps.day ?? 0, m.time,
            MsgType.allCases.firstIndex(of: m.type) ?? 0, m.selfMsg ? 1 : 0, m.nick, text, Int(m.ts), m.msgid ?? "")
        try? c.log?.write(contentsOf: Data(line.utf8))
    }

    static func close(_ c: Chan) {
        try? c.log?.close()
        c.log = nil
    }

    /// Keeps log files bounded: rewrites only the newest half when too big.
    private static func trim(_ f: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? Int, size > maxLogBytes,
              let h = try? FileHandle(forReadingFrom: f) else { return }
        let keep = maxLogBytes / 2
        try? h.seek(toOffset: UInt64(size - keep))
        let data = (try? h.readToEnd()) ?? Data()
        try? h.close()
        if let nl = data.firstIndex(of: 10) { try? data[(nl + 1)...].write(to: f) }
    }

    static func load(_ s: Server, _ c: Chan) {
        if c.type == .status { return }
        let f = logFile(s, c)
        guard let h = try? FileHandle(forReadingFrom: f) else { return }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: from)
        var data = (try? h.readToEnd()) ?? Data()
        try? h.close()
        if from > 0, let nl = data.firstIndex(of: 10) { data = data[(nl + 1)...] }
        trim(f)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(loadLines)
        var lastDate = "", lastTime = "", lastTs: Int64 = 0
        loading = true
        defer { loading = false }
        for line in lines {
            let fs = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            if fs.count < 6 { continue }
            var ts = fs.count > 6 ? Int64(fs[6]) ?? 0 : 0
            if ts <= 0 {   // logs written before 1.1 keep only the date and the time
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm"
                guard let d = df.date(from: fs[0] + " " + fs[1]) else { continue }
                ts = Int64(d.timeIntervalSince1970 * 1000)
            }
            guard let ti = Int(fs[2]), ti >= 0, ti < MsgType.allCases.count else { continue }
            Irc.addMsgAt(s, c, MsgType.allCases[ti], fs[4], fs[5], fs[3] == "1", ts: ts, msgid: fs.count > 7 && !fs[7].isEmpty ? fs[7] : nil)
            lastDate = fs[0]; lastTime = fs[1]; lastTs = ts
        }
        if lastTs > 0, lastDate.count >= 10 {
            let ds = Array(lastDate)
            Irc.addMsgAt(s, c, .info, "", t("--- historial hasta %.2s/%.2s %s ---").f(String(ds[8...9]), String(ds[5...6]), lastTime),
                         false, ts: lastTs)
        }
        c.unread = 0
        c.mention = 0
    }

    private static var sessionFile: URL { Config.dir.appendingPathComponent("session.txt") }

    public static func saveSession() {
        if restoring { return }
        var sb = ""
        for (i, s) in Irc.servers.enumerated() where i < Config.servers.count {
            for c in s.chans where c.type != .status {
                sb += "\(Config.servers[i].host)\t\(c.type == .channel ? 1 : 2)\t\(c.transIn ? 1 : 0)\t\(c.transOut ? 1 : 0)\t\(c.name)\t\(c.transLang)\t\(c.muted ? 1 : 0)\n"
            }
        }
        try? sb.write(to: sessionFile, atomically: true, encoding: .utf8)
    }

    public static func restoreSession() {
        guard let text = try? String(contentsOf: sessionFile, encoding: .utf8) else { return }
        restoring = true
        defer { restoring = false }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.count < 5 || f[4].isEmpty { continue }
            guard let sidx = Config.servers.firstIndex(where: { $0.host.eqi(f[0]) }), sidx < Irc.servers.count else { continue }
            let type: ChanType
            switch f[1] { case "1": type = .channel; case "2": type = .query; default: continue }
            let c = Irc.getChan(Irc.servers[sidx], f[4], type)
            c.transIn = f[2] == "1"
            c.transOut = f[3] == "1"
            if f.count > 5 { c.transLang = f[5] }
            if f.count > 6 { c.muted = f[6] == "1" }
        }
    }
}
