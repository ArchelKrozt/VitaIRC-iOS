import Foundation

/// Per-server state (one connection thread each).
public final class Server {
    public let idx: Int
    public var cfg: ServerCfg
    public var state = ServerState.off
    public var wantConnect = false
    public var nick = ""
    var prefixes = "~&@%+"
    public var chans: [Chan] = []
    var outq: [String] = []
    var joinAt: Int64 = 0
    var probe = false
    var pendingFocus = ""
    var capsLs = ""
    var capSasl = false
    var saslOk = false
    public var away = false
    public var capTags = false
    var capBatch = false
    public var capHistory = false
    var historyMax = 0
    public var listMask = false
    public var filehost = ""
    public var certOk = true
    var flood: [String: (count: Int, resetAt: Int64, warned: Bool)] = [:]
    public var listed: [ListedChan] = []
    public var listing = 0                      // 1 loading, 2 done
    var listSkip = 0                            // older LIST answers still arriving (dropped)
    var batches: [String: Batch] = [:]
    var offq: [OfflineMsg] = []
    var thread: Thread?
    var conn: Conn?
    let wake = NSCondition()

    init(_ idx: Int, _ cfg: ServerCfg) { self.idx = idx; self.cfg = cfg }

    public var status: Chan { chans[0] }
}

enum BatchType { case other, history, targets }

final class Batch {
    let type: BatchType
    let chanUid: Int64
    let mode: HistReq
    var msgs: [Msg] = []
    init(_ type: BatchType, _ chanUid: Int64 = 0, _ mode: HistReq = .none) { self.type = type; self.chanUid = chanUid; self.mode = mode }
}

/// Hooks to the app (translation, notifications...). The defaults do nothing (tests).
public enum IrcHooks {
    nonisolated(unsafe) public static var translateIn: (Server, Chan, Msg) -> Void = { _, _, _ in }
    nonisolated(unsafe) public static var translateOut: (Server, Chan, String) -> Void = { _, _, _ in }
    nonisolated(unsafe) public static var translationReady: () -> Bool = { false }
    nonisolated(unsafe) public static var notify: (Server, Chan, Msg) -> Void = { _, _, _ in }
    nonisolated(unsafe) public static var toast: (String) -> Void = { _ in }
    nonisolated(unsafe) public static var beep: () -> Void = {}
    /// Called (on any thread) after the state changed
    nonisolated(unsafe) public static var changed: () -> Void = {}
}

/// IRC line: tags, source nick, command and parameters.
struct Line {
    var tags: [String: String] = [:]
    var nick: String?
    var cmd = ""
    var p: [String] = []
    var last: String { p.last ?? "" }

    init(_ raw: String) {
        var s = Substring(raw)
        if s.hasPrefix("@") {
            if let sp = s.firstIndex(of: " ") {
                for tag in s[s.index(after: s.startIndex)..<sp].split(separator: ";") {
                    if let eq = tag.firstIndex(of: "=") {
                        tags[String(tag[..<eq])] = Line.unescape(String(tag[tag.index(after: eq)...]))
                    } else { tags[String(tag)] = "" }
                }
                s = s[s.index(after: sp)...].drop(while: { $0 == " " })
            } else { s = "" }
        }
        if s.hasPrefix(":") {
            let sp = s.firstIndex(of: " ")
            let src = String(s[s.index(after: s.startIndex)..<(sp ?? s.endIndex)])
            nick = src.substringBefore("!").substringBefore("@")
            s = sp.map { s[s.index(after: $0)...].drop(while: { $0 == " " }) } ?? ""
        }
        if let sp = s.firstIndex(of: " ") {
            cmd = String(s[..<sp])
            var rest = s[s.index(after: sp)...]
            while !rest.isEmpty && p.count < 16 {
                rest = rest.drop(while: { $0 == " " })
                if rest.isEmpty { break }
                if rest.first == ":" { p.append(String(rest.dropFirst())); break }
                guard let e = rest.firstIndex(of: " ") else { p.append(String(rest)); break }
                p.append(String(rest[..<e]))
                rest = rest[rest.index(after: e)...]
            }
        } else { cmd = String(s) }
    }

    static func unescape(_ v: String) -> String {
        var b = ""
        var it = v.makeIterator()
        while let c = it.next() {
            if c != "\\" { b.append(c); continue }
            guard let n = it.next() else { break }
            switch n { case ":": b.append(";"); case "s": b.append(" "); case "r": b.append("\r"); case "n": b.append("\n"); default: b.append(n) }
        }
        return b
    }

    static func escape(_ v: String) -> String {
        var b = ""
        for c in v {
            switch c { case ";": b += "\\:"; case " ": b += "\\s"; case "\\": b += "\\\\"; case "\r": b += "\\r"; case "\n": b += "\\n"; default: b.append(c) }
        }
        return b
    }
}

/// All servers and windows. Everything here needs `Irc.locked`.
public enum Irc {
    public static let maxMsgs = 500
    static let maxChans = 48
    static let maxOffline = 32
    static let maxListed = 600
    private static let floodMax = 10
    private static let floodWindow: Int64 = 60_000
    public static let ctcpVersion = "VitaIRC for iPhone"

    static let lock = NSRecursiveLock()
    @discardableResult
    public static func locked<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try block()
    }

    /// Bumped on every change; the UI redraws when it moves.
    nonisolated(unsafe) public private(set) static var revision: Int64 = 0
    public static func dirty() { revision += 1; IrcHooks.changed() }

    nonisolated(unsafe) public static var servers: [Server] = []
    nonisolated(unsafe) private static var nextUid: Int64 = 1

    /// Window on screen (written by the UI)
    nonisolated(unsafe) public static var viewSidx = -1
    nonisolated(unsafe) public static var viewUid: Int64 = 0
    nonisolated(unsafe) public static var appVisible = true

    /// Requests from the network side for the UI
    nonisolated(unsafe) public static var focusReq: (Int, Int64)?
    nonisolated(unsafe) public static var invite: (Int, String)?

    // MARK: - Windows and messages

    public static func isChannelName(_ n: String) -> Bool { guard let f = n.first else { return false }; return "#&!+".contains(f) }

    public static func findChan(_ s: Server, _ name: String) -> Chan? { s.chans.first { $0.name.eqi(name) } }
    public static func findChanUid(_ s: Server, _ uid: Int64) -> Chan? { s.chans.first { $0.uid == uid } }

    @discardableResult
    public static func getChan(_ s: Server, _ name: String, _ type: ChanType) -> Chan {
        if let c = findChan(s, name) { return c }
        if s.chans.count >= maxChans { return s.status }
        let c = Chan(nextUid, type, name)
        nextUid += 1
        s.chans.append(c)
        if type != .status {
            History.load(s, c)
            History.saveSession()
        }
        dirty()
        return c
    }

    public static func closeChan(_ s: Server, _ c: Chan) {
        if c.type == .status { return }
        s.chans.removeAll { $0 === c }
        History.close(c)
        History.saveSession()
        dirty()
    }

    public static func chanLang(_ c: Chan) -> String { c.transLang.ifEmpty(Config.langIn) }

    public static func isIgnored(_ nick: String?) -> Bool {
        guard let n = nick, !n.isEmpty, !Config.ignore.isBlank else { return false }
        return Config.ignore.split(anyOf: ", ").contains { !$0.isBlank && IrcText.globMatch($0.trimmed, n) }
    }

    static func isHighlight(_ s: Server, _ text: String) -> Bool {
        let me = s.nick.ifEmpty(s.cfg.nick)
        if !me.isEmpty && IrcText.containsWord(text, me) { return true }
        return Config.highlight.split(separator: ",").map { String($0).trimmed }.contains { !$0.isEmpty && IrcText.containsWord(text, $0) }
    }

    public static func myPrefix(_ s: Server, _ c: Chan) -> Character? { c.users.first { $0.nick.eqi(s.nick) }?.prefix }

    private static func pushMsg(_ c: Chan, _ m: Msg) {
        if c.msgs.count >= maxMsgs { c.msgs.removeFirst() }
        c.msgs.append(m)
    }

    private static func dateSep(_ c: Chan, _ ts: Int64) {
        c.nextId += 1
        pushMsg(c, Msg(c.nextId, .date, "", "", [], false, ts, nil))
        c.lastYmd = TimeUtil.ymd(ts)
    }

    /// Adds a message to a window (now, or at ts when replaying a log or history).
    @discardableResult
    static func addMsgAt(_ s: Server, _ c: Chan, _ type: MsgType, _ nick: String?, _ text: String, _ selfMsg: Bool,
                         ts: Int64 = 0, msgid: String? = nil, pending: Bool = false) -> Msg {
        let when = ts > 0 ? ts : TimeUtil.now()
        if c.type != .status && type != .date && TimeUtil.ymd(when) != c.lastYmd { dateSep(c, when) }
        let f = IrcText.parse(text)
        c.nextId += 1
        let m = Msg(c.nextId, type, nick ?? "", String(f.text.prefix(1000)), f.spans, selfMsg, when, msgid)
        m.pending = pending
        pushMsg(c, m)
        let visible = appVisible && viewSidx == s.idx && viewUid == c.uid
        if !pending { History.log(s, c, m) }
        if History.loading {
            if m.chatty && !selfMsg && c.type != .status && isHighlight(s, m.text) { m.highlight = true }
        } else if m.chatty && !selfMsg {
            if c.type != .status && isHighlight(s, m.text) { m.highlight = true }
            let notify = m.highlight || c.type == .query
            let quiet = c.muted
            if !visible {
                c.unread += 1
                if notify {
                    c.mention += 1
                    if !quiet { IrcHooks.notify(s, c, m) }
                }
            } else if notify && !quiet && Config.sound {
                IrcHooks.beep()
            }
            if c.transIn && !IrcText.shouldSkipTranslation(m.text) {
                m.transState = .pending
                IrcHooks.translateIn(s, c, m)
            }
        }
        dirty()
        return m
    }

    @discardableResult
    static func addMsg(_ s: Server, _ c: Chan, _ type: MsgType, _ nick: String?, _ text: String, _ selfMsg: Bool = false, line: Line? = nil) -> Msg {
        let ts = line?.tags["time"].flatMap { TimeUtil.parseIso($0) } ?? 0
        let id = line?.tags["msgid"].flatMap { $0.isEmpty ? nil : $0 }
        return addMsgAt(s, c, type, nick, text, selfMsg, ts: ts, msgid: id)
    }

    private static func status(_ s: Server, _ type: MsgType, _ text: String) { addMsg(s, s.status, type, nil, text) }

    /// Window for replies the user asked for (WHOIS, errors...)
    private static func replyChan(_ s: Server) -> Chan {
        (viewSidx == s.idx ? findChanUid(s, viewUid) : nil) ?? s.status
    }

    // MARK: - Users

    private static func prefixRank(_ s: Server, _ p: Character?) -> Int {
        guard let p = p else { return 99 }
        if let i = s.prefixes.firstIndex(of: p) { return s.prefixes.distance(from: s.prefixes.startIndex, to: i) }
        return 50
    }

    static func sortUsers(_ s: Server, _ c: Chan) {
        c.users.sort { a, b in
            let ra = prefixRank(s, a.prefix), rb = prefixRank(s, b.prefix)
            return ra != rb ? ra < rb : a.nick.lowercased() < b.nick.lowercased()
        }
    }

    private static func findUser(_ c: Chan, _ nick: String) -> ChanUser? { c.users.first { $0.nick.eqi(nick) } }

    private static func addUser(_ s: Server, _ c: Chan, _ entry: String) {
        var e = Substring(entry)
        var prefix: Character? = nil
        while let f = e.first, s.prefixes.contains(f) {   // multi-prefix: keep the highest
            if prefix == nil || prefixRank(s, f) < prefixRank(s, prefix) { prefix = f }
            e = e.dropFirst()
        }
        let nick = String(e).substringBefore("!")
        if nick.isEmpty { return }
        if let u = findUser(c, nick) { u.prefix = prefix } else { c.users.append(ChanUser(nick, prefix)) }
    }

    @discardableResult
    private static func removeUser(_ c: Chan, _ nick: String) -> Bool {
        let n = c.users.count
        c.users.removeAll { $0.nick.eqi(nick) }
        return c.users.count != n
    }

    // MARK: - Outgoing

    static func sendRaw(_ s: Server, _ line: String) {
        if s.outq.count >= 64 { return }
        // never allow embedded line breaks to inject extra commands
        var l = line.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if l.utf8.count > 510 {
            var b = Array(l.utf8.prefix(510))
            while !b.isEmpty, String(bytes: b, encoding: .utf8) == nil { b.removeLast() }
            l = String(decoding: b, as: UTF8.self)
        }
        s.outq.append(l + "\r\n")
    }

    /// Splits long text at word/UTF-8 boundaries so each PRIVMSG fits in 512 bytes.
    public static func splitText(_ text: String, max: Int = 380) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.utf8.count <= max { out.append(String(rest)); break }
            var bytes = 0
            var cut = rest.startIndex
            for i in rest.indices {
                let b = rest[i].utf8.count
                if bytes + b > max { break }
                bytes += b
                cut = rest.index(after: i)
            }
            // prefer the last space if it is close
            if let sp = rest[..<cut].lastIndex(of: " "), rest.distance(from: sp, to: cut) < 60, sp > rest.startIndex { cut = sp }
            out.append(String(rest[..<cut]))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        return out
    }

    private static func sendText(_ s: Server, _ target: String, _ c: Chan?, _ text: String, _ action: Bool) {
        for chunk in splitText(text) {
            sendRaw(s, action ? "PRIVMSG \(target) :\u{01}ACTION \(chunk)\u{01}" : "PRIVMSG \(target) :\(chunk)")
            if let c = c { addMsg(s, c, action ? .action : .msg, s.nick, chunk, true) }
        }
    }

    /// Offline: show the message now (dimmed) and send it after reconnecting.
    private static func queueOffline(_ s: Server, _ c: Chan, _ text: String, _ action: Bool) {
        if s.offq.count >= maxOffline {
            addMsg(s, c, .error, nil, t("No conectado: el mensaje no se envió."))
            return
        }
        let m = addMsgAt(s, c, action ? .action : .msg, s.nick.ifEmpty(s.cfg.nick), text, true, pending: true)
        s.offq.append(OfflineMsg(chanUid: c.uid, msgId: m.id, action: action, text: text))
        if s.offq.count == 1 { IrcHooks.toast(t("Sin conexión: se enviará al reconectar")) }
    }

    /// Sends what was typed offline in one window (only = nil: every query).
    private static func flushOffline(_ s: Server, _ only: Chan?) {
        var keep: [OfflineMsg] = []
        for q in s.offq {
            let c = findChanUid(s, q.chanUid)
            if let c = c, (only != nil ? c !== only : c.type != .query) { keep.append(q); continue }
            guard let ch = c else { continue }        // a closed window drops its queue
            sendText(s, ch.name, nil, q.text, q.action)
            if let m = ch.findMsg(q.msgId) {
                // it is said now: it moves after what arrived meanwhile
                ch.msgs.removeAll { $0 === m }
                m.pending = false
                m.ts = TimeUtil.now()
                m.time = TimeUtil.hhmm(m.ts)
                if TimeUtil.ymd(m.ts) != ch.lastYmd { dateSep(ch, m.ts) }
                pushMsg(ch, m)
                History.log(s, ch, m)
            }
        }
        s.offq = keep
        dirty()
    }

    public static func sendPrivmsg(_ sidx: Int, _ chanUid: Int64, _ text: String) {
        locked {
            guard sidx < servers.count, let c = findChanUid(servers[sidx], chanUid), c.type != .status else { return }
            let s = servers[sidx]
            if s.state != .online { queueOffline(s, c, text, false) } else { sendText(s, c.name, c, text, false) }
        }
    }

    private static let helpLines = [
        "Comandos disponibles:",
        "/join #canal [clave]  /part [motivo]  /close",
        "/msg nick texto  /query nick  /me acción  /notice destino texto",
        "/nick nuevo  /topic [texto]  /whois nick  /list",
        "/connect  /disconnect  /quote COMANDO CRUDO  /clear",
        "/away [motivo]  /back  /ignore [nick]  /unignore nick",
        "/op /deop /voice /devoice nick  /kick nick [motivo]  /ban nick  /kickban nick",
        "Cualquier otro /COMANDO se envía tal cual al servidor.",
    ]

    private static func editIgnore(_ nick: String, _ add: Bool) {
        var list = Config.ignore.split(anyOf: ", ").filter { !$0.isBlank && !$0.eqi(nick) }
        if add { list.append(nick) }
        Config.ignore = list.joined(separator: ",")
        Config.save()
    }

    /// Text typed into a window: a command, or a message.
    public static func userInput(_ sidx: Int, _ chanUid: Int64, _ input: String) {
        locked { userInputLocked(sidx, chanUid, input) }
    }

    private static func userInputLocked(_ sidx: Int, _ chanUid: Int64, _ input: String) {
        let text = input.trimmed
        guard !text.isEmpty, sidx >= 0, sidx < servers.count else { return }
        let s = servers[sidx]
        let c = findChanUid(s, chanUid) ?? s.status

        if text.first != "/" || text.hasPrefix("//") {
            let body = text.first == "/" ? String(text.dropFirst()) : text
            if c.type == .status { addMsg(s, c, .error, nil, t("Esta es la ventana del servidor. Usa /join #canal o /help.")) }
            else if s.state != .online { queueOffline(s, c, body, false) }
            else if c.transOut && IrcHooks.translationReady() && !IrcText.shouldSkipTranslation(body) { IrcHooks.translateOut(s, c, body) }
            else { sendText(s, c.name, c, body, false) }
            return
        }
        let afterSlash = text.dropFirst()
        let cmd = String(afterSlash.prefix { $0 != " " }).uppercased()
        let args = afterSlash.contains(" ") ? String(afterSlash.drop { $0 != " " }).trimLeadingSpaces() : ""
        let who = args.substringBefore(" ")
        let rest = args.contains(" ") ? args.substringAfter(" ") : ""

        switch cmd {
        case "CONNECT": connect(sidx); return
        case "DISCONNECT", "QUIT": disconnect(sidx, args.nonEmpty); return
        case "HELP": for l in helpLines { addMsg(s, c, .info, nil, t(l)) }; return
        case "CLEAR": c.msgs.removeAll(); c.lastYmd = 0; dirty(); return
        case "QUERY":
            if !who.isEmpty {
                let q = getChan(s, who, .query)
                focusReq = (sidx, q.uid)
                if !rest.isEmpty && s.state == .online { sendText(s, q.name, q, rest, false) }
                dirty()
            }
            return
        case "IGNORE", "UNIGNORE":
            if !who.isEmpty {
                editIgnore(who, cmd == "IGNORE")
                addMsg(s, c, .info, nil, (cmd == "IGNORE" ? t("Ignorando a %s") : t("Ya no ignoras a %s")).f(who))
            } else {
                addMsg(s, c, .info, nil, t("Ignorados: %s").f(Config.ignore.ifEmpty(t("(ninguno)"))))
            }
            return
        case "CLOSE":
            if c.type == .channel && c.joined && s.state == .online { sendRaw(s, "PART \(c.name) :VitaIRC") }
            closeChan(s, c)
            return
        case "ME":
            if s.state != .online {
                if c.type != .status && !args.isEmpty { queueOffline(s, c, args, true) }
                return
            }
        default: break
        }
        if s.state != .online {
            addMsg(s, c, .error, nil, t("No conectado. Usa /connect."))
            return
        }
        let isChan = c.type == .channel
        switch cmd {
        case "AWAY": sendRaw(s, args.isEmpty ? "AWAY" : "AWAY :\(args)")
        case "BACK": sendRaw(s, "AWAY")
        case "OP", "DEOP", "VOICE", "DEVOICE":
            if !who.isEmpty && isChan {
                let sign = cmd.hasPrefix("DE") ? "-" : "+"
                let mode = cmd.hasSuffix("OP") ? "o" : "v"
                sendRaw(s, "MODE \(c.name) \(sign)\(mode) \(who)")
            }
        case "KICK": if !who.isEmpty && isChan { sendRaw(s, "KICK \(c.name) \(who) :\(rest.ifEmpty("VitaIRC"))") }
        case "BAN", "KICKBAN":
            if !who.isEmpty && isChan {
                sendRaw(s, "MODE \(c.name) +b \(who)!*@*")
                if cmd == "KICKBAN" { sendRaw(s, "KICK \(c.name) \(who) :\(rest.ifEmpty("VitaIRC"))") }
            }
        case "JOIN", "J":
            if !who.isEmpty {
                let name = isChannelName(who) ? who : "#" + who
                sendRaw(s, rest.isEmpty ? "JOIN \(name)" : "JOIN \(name) \(rest)")
                s.pendingFocus = name
            }
        case "PART", "LEAVE": if isChan { sendRaw(s, "PART \(c.name) :\(args.ifEmpty("VitaIRC"))") }
        case "ME": if c.type != .status && !args.isEmpty { sendText(s, c.name, c, args, true) }
        case "MSG", "NOTICE":
            if !who.isEmpty && !rest.isEmpty {
                if cmd == "NOTICE" {
                    sendRaw(s, "NOTICE \(who) :\(rest)")
                    addMsg(s, c, .notice, s.nick, rest, true)
                } else {
                    let tch = isChannelName(who) ? findChan(s, who) : getChan(s, who, .query)
                    if let tch = tch { sendText(s, tch.name, tch, rest, false) } else { sendRaw(s, "PRIVMSG \(who) :\(rest)") }
                }
            }
        case "NICK": if !args.isEmpty { sendRaw(s, "NICK \(args)") }
        case "TOPIC": if isChan { sendRaw(s, args.isEmpty ? "TOPIC \(c.name)" : "TOPIC \(c.name) :\(args)") }
        case "WHOIS": if !args.isEmpty { sendRaw(s, "WHOIS \(args)") }
        case "LIST":
            // a list still arriving: its rest is not part of the new one
            if s.listing == 1 && s.listSkip < 8 { s.listSkip += 1 }
            s.listed.removeAll()
            s.listing = 1
            sendRaw(s, args.isEmpty ? "LIST" : "LIST \(args)")    // e.g. /list *vita*
        case "QUOTE", "RAW": if !args.isEmpty { sendRaw(s, args) }
        default: sendRaw(s, args.isEmpty ? cmd : "\(cmd) \(args)")
        }
        dirty()
    }

    // MARK: - IRCv3 chathistory

    /// Time of the newest (or oldest) real message in a window, 0 if none.
    private static func edgeTs(_ c: Chan, _ newest: Bool) -> Int64 {
        let ok: (Msg) -> Bool = { $0.chatty && !$0.pending && $0.ts > 0 }
        return (newest ? c.msgs.last(where: ok) : c.msgs.first(where: ok))?.ts ?? 0
    }

    private static func historyLimit(_ s: Server, _ want: Int) -> Int { (1..<want).contains(s.historyMax) ? s.historyMax : want }
    private static func historyBusy(_ c: Chan) -> Bool { c.histReq != .none && TimeUtil.now() - c.histReqAt < 20000 }

    /// What was said in a window while we were away (after joining it).
    private static func requestLatest(_ s: Server, _ c: Chan) {
        if !s.capHistory || c.type == .status || historyBusy(c) { return }
        let lim = historyLimit(s, 100)
        let tsv = edgeTs(c, true)
        sendRaw(s, tsv > 0 ? "CHATHISTORY LATEST \(c.name) timestamp=\(TimeUtil.iso(tsv)) \(lim)" : "CHATHISTORY LATEST \(c.name) * \(lim)")
        c.histReq = .latest
        c.histReqAt = TimeUtil.now()
        c.histSince = tsv
    }

    /// Messages older than the oldest one in the window. Returns true when a request was sent.
    @discardableResult
    public static func requestOlder(_ s: Server, _ c: Chan) -> Bool {
        if !s.capHistory || s.state != .online || c.type == .status || c.histEnd || historyBusy(c) { return false }
        let room = maxMsgs - c.msgs.count - 20
        if room < 10 {
            IrcHooks.toast(t("No caben más mensajes en esta ventana"))
            c.histEnd = true
            return false
        }
        let lim = historyLimit(s, min(room, 50))
        let tsv = edgeTs(c, false)
        if tsv > 0 {
            sendRaw(s, "CHATHISTORY BEFORE \(c.name) timestamp=\(TimeUtil.iso(tsv)) \(lim)")
            c.histReq = .before
        } else {
            sendRaw(s, "CHATHISTORY LATEST \(c.name) * \(lim)")
            c.histReq = .latest
            c.histSince = 0
        }
        c.histReqAt = TimeUtil.now()
        dirty()
        return true
    }

    private static func batchOpen(_ s: Server, _ ref: String, _ type: String, _ param: String) {
        if s.batches.count >= 8 { return }
        if type == "chathistory" && !param.isEmpty {
            let c = isChannelName(param) ? findChan(s, param) : getChan(s, param, .query)
            if let c = c, c.type != .status {
                if c.histReq == .none { c.histSince = edgeTs(c, true) }   // not asked for: new is what we lack
                s.batches[ref] = Batch(.history, c.uid, c.histReq != .none ? c.histReq : .latest)
            } else { s.batches[ref] = Batch(.other) }
        } else if type == "draft/chathistory-targets" || type == "chathistory-targets" {
            s.batches[ref] = Batch(.targets)
        } else { s.batches[ref] = Batch(.other) }
    }

    private static func historyBatch(_ s: Server, _ l: Line) -> Batch? {
        guard let ref = l.tags["batch"], let b = s.batches[ref], b.type == .history else { return nil }
        return b
    }

    /// Messages inside a chathistory batch are collected and merged at its end.
    private static func historyCollect(_ s: Server, _ l: Line, _ type: MsgType, _ nick: String, _ text: String) -> Bool {
        guard let b = historyBatch(s, l) else { return false }
        let f = IrcText.parse(text)
        let ts = l.tags["time"].flatMap { TimeUtil.parseIso($0) } ?? TimeUtil.now()
        b.msgs.append(Msg(0, type, nick, String(f.text.prefix(1000)), f.spans, isMe(s, nick), ts, l.tags["msgid"].flatMap { $0.isEmpty ? nil : $0 }))
        return true
    }

    private static func sameMsg(_ a: Msg, _ b: Msg) -> Bool {
        if a.msgid != nil && a.msgid == b.msgid { return true }
        let d = abs(a.ts - b.ts)
        // a bouncer can renumber what it stores; old logs keep minutes only
        let window: Int64 = (a.msgid != nil && b.msgid != nil) ? 1000 : 90000
        return d < window && a.type == b.type && a.nick.eqi(b.nick) && a.text == b.text
    }

    /// Merges a chathistory batch into the window in time order, skipping what is already there.
    private static func chanMerge(_ s: Server, _ c: Chan, _ b: Batch) {
        var add: [Msg] = []
        for a in b.msgs {
            if isIgnored(a.nick) { continue }
            if c.msgs.contains(where: { $0.chatty && sameMsg($0, a) }) || add.contains(where: { sameMsg($0, a) }) { continue }
            add.append(a)
        }
        b.msgs.removeAll()
        if add.isEmpty { return }
        add.sort { $0.ts < $1.ts }
        let since = b.mode == .before ? Int64.max : c.histSince
        let firstNew = c.nextId + 1
        var merged: [Msg] = []
        merged.reserveCapacity(c.msgs.count + add.count)
        var j = 0
        func takeAdd() { c.nextId += 1; add[j].id = c.nextId; merged.append(add[j]); j += 1 }
        for m in c.msgs where m.type != .date {
            while j < add.count && add[j].ts < m.ts { takeAdd() }
            merged.append(m)
        }
        while j < add.count { takeAdd() }
        // day separators again
        c.msgs.removeAll()
        var ymd = 0
        for m in merged {
            let d = TimeUtil.ymd(m.ts)
            if d != ymd {
                ymd = d
                c.nextId += 1
                c.msgs.append(Msg(c.nextId, .date, "", "", [], false, m.ts, nil))
            }
            c.msgs.append(m)
        }
        if c.msgs.count > maxMsgs { c.msgs.removeFirst(c.msgs.count - maxMsgs) }
        c.lastYmd = ymd

        // what is newer than the window had: log it, count it, translate it
        let visible = appVisible && viewSidx == s.idx && viewUid == c.uid
        var mentions = 0
        var translate = 12
        for m in c.msgs.reversed() {
            if m.id < firstNew || m.type == .date { continue }
            m.time = TimeUtil.hhmm(m.ts)
            if !m.selfMsg && c.type != .status && isHighlight(s, m.text) { m.highlight = true }
            if m.ts <= since || m.selfMsg { continue }
            if !visible {
                c.unread += 1
                if m.highlight || c.type == .query { c.mention += 1; mentions += 1 }
            }
            if c.transIn && translate > 0 && !IrcText.shouldSkipTranslation(m.text) {
                m.transState = .pending
                IrcHooks.translateIn(s, c, m)
                translate -= 1
            }
        }
        for m in c.msgs where m.id >= firstNew && m.type != .date && m.ts > since { History.log(s, c, m) }
        if mentions > 0 && !c.muted {
            IrcHooks.toast(t("%d mensajes para ti en %s mientras no estabas").f(mentions, c.name))
            if let m = c.msgs.last(where: { $0.id >= firstNew && $0.highlight }) { IrcHooks.notify(s, c, m) }
        }
        dirty()
    }

    private static func batchClose(_ s: Server, _ ref: String) {
        guard let b = s.batches.removeValue(forKey: ref) else { return }
        if b.type == .history, let c = findChanUid(s, b.chanUid) {
            if b.mode == .before && b.msgs.isEmpty { c.histEnd = true }
            c.histReq = .none
            chanMerge(s, c, b)
        }
        dirty()
    }

    /// Nicks that talk to everybody: their history is not worth a window.
    private static func isService(_ n: String) -> Bool {
        n.contains(".") || ["NickServ", "ChanServ", "SaslServ", "MemoServ", "HostServ", "OperServ", "BotServ", "BouncerServ", "*status", "Global"].contains { $0.eqi(n) }
    }

    // MARK: - Reactions (+draft/react)

    private static func reactApply(_ m: Msg, _ emoji: String, _ nick: String, _ add: Bool, _ mine: Bool) {
        if emoji.isEmpty { return }
        let who = nick.lowercased()
        if m.reacts == nil { if add { m.reacts = [] } else { return } }
        if add {
            var e = m.reacts!.first { $0.emoji == emoji }
            if e == nil {
                if m.reacts!.count >= 6 { return }
                e = React(emoji)
                m.reacts!.append(e!)
            }
            if !e!.who.insert(who).inserted { return }     // already counted
            e!.count += 1
            if mine { e!.mine = true }
        } else {
            guard let e = m.reacts!.first(where: { $0.emoji == emoji }), e.who.remove(who) != nil else { return }
            e.count -= 1
            if mine { e.mine = false }
            if e.count <= 0 { m.reacts!.removeAll { $0 === e } }
            if m.reacts!.isEmpty { m.reacts = nil }
        }
        dirty()
    }

    public static func canReact(_ s: Server, _ m: Msg) -> Bool { s.capTags && s.state == .online && m.msgid != nil && m.chatty }

    public static func sendReact(_ s: Server, _ c: Chan, _ m: Msg, _ emoji: String) {
        guard canReact(s, m), let id = m.msgid else { return }
        let mine = m.reacts?.contains { $0.emoji == emoji && $0.mine } == true
        sendRaw(s, "@+draft/\(mine ? "unreact" : "react")=\(Line.escape(emoji));+draft/reply=\(Line.escape(id)) TAGMSG \(c.name)")
        reactApply(m, emoji, s.nick, !mine, true)
    }

    // MARK: - Incoming

    private static func isMe(_ s: Server, _ nick: String?) -> Bool { nick?.eqi(s.nick) ?? false }

    private static func useSasl(_ s: Server) -> Bool { !s.cfg.password.isEmpty && (s.cfg.auth == ServerCfg.authSasl || s.cfg.auth == ServerCfg.authAuto) }
    private static func accountName(_ s: Server) -> String { s.cfg.user.ifEmpty(s.cfg.nick) }

    /// "@#chan" (a message to the channel's operators) -> "#chan"
    private static func stripStatusmsg(_ target: String) -> String {
        if !isChannelName(target), let f = target.first, "@%~".contains(f), isChannelName(String(target.dropFirst())) { return String(target.dropFirst()) }
        return target
    }

    /// Private-message flood protection: true when the message must be dropped.
    private static func pmFlooding(_ s: Server, _ nick: String) -> Bool {
        let now = TimeUtil.now()
        let key = nick.lowercased()
        if s.flood[key] == nil {
            if s.flood.count >= 16, let oldest = s.flood.min(by: { $0.value.resetAt < $1.value.resetAt })?.key { s.flood.removeValue(forKey: oldest) }
            s.flood[key] = (0, 0, false)
        }
        var e = s.flood[key]!
        if now > e.resetAt { e = (0, now + floodWindow, false) }
        e.count += 1
        defer { s.flood[key] = e }
        if e.count <= floodMax { return false }
        if !e.warned {
            e.warned = true
            addMsg(s, s.status, .error, nil, t("Flood de %s: ignorando sus privados por un minuto").f(nick))
        }
        return true
    }

    private static func doAutojoin(_ s: Server) {
        for ch in s.cfg.channels.split(anyOf: ", ") where !ch.isBlank { sendRaw(s, "JOIN \(ch.trimmed)") }
        // re-join channels that were open before a reconnect
        for c in s.chans where c.type == .channel && !c.joined && !IrcText.containsWord(s.cfg.channels, c.name) { sendRaw(s, "JOIN \(c.name)") }
        flushOffline(s, nil)      // channels get theirs once joined
    }

    private static func handleCtcp(_ s: Server, _ l: Line, _ target: String, _ text: String) {
        if isIgnored(l.nick) { return }
        let body = String(text.dropFirst()).substringBefore("\u{01}")
        let cmd = body.substringBefore(" ")
        let arg = body.contains(" ") ? body.substringAfter(" ") : ""
        guard let nick = l.nick else { return }
        if cmd == "ACTION" {
            let me = isMe(s, nick)
            let chan = isChannelName(target)
            if historyCollect(s, l, .action, nick, arg) { return }
            if me && isMe(s, target) && historyBatch(s, l) == nil { return }
            let c = getChan(s, chan || me ? target : nick, chan ? .channel : .query)
            addMsg(s, c, .action, nick, arg, me, line: l)
            return
        }
        if historyBatch(s, l) != nil || isMe(s, nick) { return }     // old or my own CTCP requests: no replies
        switch cmd {
        case "VERSION": sendRaw(s, "NOTICE \(nick) :\u{01}VERSION \(ctcpVersion)\u{01}")
        case "PING": sendRaw(s, "NOTICE \(nick) :\u{01}PING \(arg)\u{01}")
        case "TIME": sendRaw(s, "NOTICE \(nick) :\u{01}TIME \(TimeUtil.hhmm(TimeUtil.now()))\u{01}")
        default: break
        }
    }

    static func handleLine(_ s: Server, _ raw: String) {
        let l = Line(raw)
        let cmd = l.cmd
        if cmd.isEmpty { return }
        let last = l.last
        switch cmd {
        case "PING": sendRaw(s, "PONG :\(last)"); return
        case "PONG": return
        case "PRIVMSG":
            guard l.p.count >= 2, let nick = l.nick else { return }
            let target = stripStatusmsg(l.p[0])
            let text = l.p[1]
            if text.hasPrefix("\u{01}") { handleCtcp(s, l, target, text); return }
            // my own messages come back from a bouncer when sent from another client
            let me = isMe(s, nick)
            let chan = isChannelName(target)
            if isIgnored(nick) { return }
            if me && isMe(s, target) && historyBatch(s, l) == nil { return }   // to myself: already shown when sent
            if historyCollect(s, l, .msg, nick, text) { return }
            if !chan && !me && pmFlooding(s, nick) { return }
            let c = getChan(s, chan || me ? target : nick, chan ? .channel : .query)
            addMsg(s, c, .msg, nick, text, me, line: l)
            return
        case "NOTICE":
            guard l.p.count >= 2 else { return }
            let target = stripStatusmsg(l.p[0])
            let nick = l.nick
            if let n = nick, isIgnored(n) || (isMe(s, target) && s.state == .online && !n.contains(".") && pmFlooding(s, n)) { return }
            var text = l.p[1]
            if text.hasPrefix("\u{01}") { text = String(text.dropFirst()) }     // CTCP replies
            text = text.substringBefore("\u{01}")
            if let n = nick, !n.contains("."), historyCollect(s, l, .notice, n, text) { return }
            let c: Chan
            if nick == nil || nick!.contains(".") || s.state != .online { c = s.status }
            else if isChannelName(target) { c = getChan(s, target, .channel) }
            else { c = findChan(s, nick!) ?? replyChan(s) }
            addMsg(s, c, .notice, nick ?? "", text, false, line: l)
            if nick?.eqi("NickServ") == true && s.cfg.password.isEmpty && (text.containsi("is registered") || text.containsi("identify via")) {
                IrcHooks.toast(t("Nick registrado: pon tu contraseña en Servidores para identificarte solo"))
            }
            return
        case "JOIN":
            guard !l.p.isEmpty, let nick = l.nick else { return }
            let name = l.p[0]
            let c = getChan(s, name, .channel)
            if isMe(s, nick) {
                c.joined = true
                c.users.removeAll()
                addMsg(s, c, .join, nil, t("Te uniste al canal"))
                if s.pendingFocus.eqi(name) {
                    s.pendingFocus = ""
                    focusReq = (s.idx, c.uid)
                }
                requestLatest(s, c)
                flushOffline(s, c)
            } else {
                addUser(s, c, nick)
                sortUsers(s, c)
                if Config.showJoins { addMsg(s, c, .join, nil, t("%s se unió").f(nick), line: l) }
            }
            return
        case "PART":
            guard !l.p.isEmpty, let nick = l.nick, let c = findChan(s, l.p[0]) else { return }
            if isMe(s, nick) {
                c.joined = false
                c.users.removeAll()
                addMsg(s, c, .part, nil, t("Saliste del canal"))
            } else {
                removeUser(c, nick)
                if Config.showJoins {
                    addMsg(s, c, .part, nil, t("%s salió%s%s").f(nick, l.p.count > 1 ? ": " : "", l.p.count > 1 ? l.p[1] : ""), line: l)
                }
            }
            dirty()
            return
        case "QUIT":
            guard let nick = l.nick else { return }
            let b = t("%s se desconectó%s%s").f(nick, l.p.isEmpty ? "" : ": ", l.p.first ?? "")
            for c in s.chans {
                let had = removeUser(c, nick)
                let isQuery = c.type == .query && c.name.eqi(nick)
                if (had && Config.showJoins) || isQuery { addMsg(s, c, .quit, nil, b, line: l) }
            }
            dirty()
            return
        case "KICK":
            guard l.p.count >= 2, let c = findChan(s, l.p[0]) else { return }
            let b = t("%s fue expulsado por %s: %s").f(l.p[1], l.nick ?? "?", l.p.count > 2 ? l.p[2] : "")
            if isMe(s, l.p[1]) {
                c.joined = false
                c.users.removeAll()
                addMsg(s, c, .error, nil, b)
                IrcHooks.toast(t("Fuiste expulsado de %s").f(c.name))
            } else {
                removeUser(c, l.p[1])
                addMsg(s, c, .kick, nil, b, line: l)
            }
            return
        case "NICK":
            guard !l.p.isEmpty, let nick = l.nick else { return }
            let nn = l.p[0]
            let b = t("%s ahora es %s").f(nick, nn)
            let me = isMe(s, nick)
            if me { s.nick = nn }
            for c in s.chans {
                if let u = findUser(c, nick) { u.nick = nn; addMsg(s, c, .nick, nil, b, line: l) }
                else if c.type == .query && c.name.eqi(nick) { c.name = nn; addMsg(s, c, .nick, nil, b, line: l) }
            }
            if me { addMsg(s, s.status, .nick, nil, b) }
            return
        case "TOPIC":
            guard l.p.count >= 2, let c = findChan(s, l.p[0]) else { return }
            c.topic = IrcText.strip(l.p[1])
            addMsg(s, c, .topic, nil, t("%s cambió el tema: %s").f(l.nick ?? "?", l.p[1]), line: l)
            return
        case "MODE":
            guard l.p.count >= 2 else { return }
            let c = isChannelName(l.p[0]) ? findChan(s, l.p[0]) : nil
            addMsg(s, c ?? s.status, .mode, nil, t("%s establece modo %s").f(l.nick ?? "?", l.p.dropFirst().joined(separator: " ")), line: l)
            if let c = c { sendRaw(s, "NAMES \(c.name)") }      // refresh prefixes
            return
        case "CAP":
            guard l.p.count >= 3 else { return }
            switch l.p[1] {
            case "LS":
                s.capsLs += last + " "
                if l.p.count >= 4 && l.p[2] == "*" { return }
                let offered = Set(s.capsLs.split(separator: " ").map { String($0).substringBefore("=") })
                let wanted = ["server-time", "znc.in/server-time-iso", "multi-prefix", "away-notify", "batch", "message-tags", "draft/chathistory", "sasl"]
                var req: [String] = []
                for w in wanted {
                    if w == "sasl" && !useSasl(s) { continue }
                    if w == "znc.in/server-time-iso" && req.contains("server-time") { continue }
                    if offered.contains(w) { req.append(w) }
                }
                sendRaw(s, req.isEmpty ? "CAP END" : "CAP REQ :\(req.joined(separator: " "))")
            case "ACK":
                var sasl = false
                for tk in last.split(separator: " ") where !tk.hasPrefix("-") {
                    switch tk {
                    case "sasl": sasl = true
                    case "message-tags": s.capTags = true
                    case "batch": s.capBatch = true
                    case "draft/chathistory": s.capHistory = true
                    default: break
                    }
                }
                s.capHistory = s.capHistory && s.capBatch
                if sasl { s.capSasl = true; sendRaw(s, "AUTHENTICATE PLAIN") }
                else if s.state != .online { sendRaw(s, "CAP END") }
            case "NAK": if s.state != .online { sendRaw(s, "CAP END") }
            default: break
            }
            return
        case "BATCH":
            guard let r = l.p.first else { return }
            if r.hasPrefix("+") && l.p.count >= 2 { batchOpen(s, String(r.dropFirst()), l.p[1], l.p.count > 2 ? l.p[2] : "") }
            else if r.hasPrefix("-") { batchClose(s, String(r.dropFirst())) }
            return
        case "CHATHISTORY":
            if l.p.count >= 2 && l.p[0] == "TARGETS" {
                let tg = l.p[1]
                if !isChannelName(tg) && !isMe(s, tg) && !isService(tg) && !isIgnored(tg) { requestLatest(s, getChan(s, tg, .query)) }
            }
            return
        case "FAIL":
            guard !l.p.isEmpty else { return }
            if l.p[0] == "CHATHISTORY" { s.chans.forEach { $0.histReq = .none }; dirty() } else { status(s, .error, last) }
            return
        case "TAGMSG":
            guard !l.p.isEmpty, let nick = l.nick else { return }
            let react = l.tags["+draft/react"] ?? ""
            let unreact = l.tags["+draft/unreact"] ?? ""
            let reply = l.tags["+draft/reply"] ?? ""
            let emoji = react.ifEmpty(unreact)
            if emoji.isEmpty || reply.isEmpty || isIgnored(nick) { return }
            let me = isMe(s, nick)
            if let m = findChan(s, isChannelName(l.p[0]) || me ? l.p[0] : nick)?.findMsgId(reply) {
                reactApply(m, emoji, nick, !react.isEmpty, me)
            }
            return
        case "AWAY":
            guard let nick = l.nick else { return }
            for c in s.chans { findUser(c, nick)?.away = !(l.p.first ?? "").isEmpty }
            dirty()
            return
        case "INVITE":
            guard l.p.count >= 2, let nick = l.nick, !isIgnored(nick) else { return }
            invite = (s.idx, l.p[1])
            addMsg(s, replyChan(s), .info, nil, t("%s te invitó a %s. Usa /join %s").f(nick, l.p[1], l.p[1]))
            IrcHooks.toast(t("%s te invitó a %s").f(nick, l.p[1]))
            return
        case "AUTHENTICATE":
            if l.p.first == "+" {
                let user = accountName(s)
                let token = Data("\(user)\u{0}\(user)\u{0}\(s.cfg.password)".utf8).base64EncodedString()
                sendRaw(s, "AUTHENTICATE " + token)
            }
            return
        case "ERROR": status(s, .error, t("Servidor: %s").f(last)); return
        default: break
        }
        guard cmd.count == 3, let num = Int(cmd) else { return }
        numeric(s, num, l)
    }

    private static func numeric(_ s: Server, _ num: Int, _ l: Line) {
        let last = l.last
        switch num {
        case 1:
            s.state = .online
            if let n = l.p.first { s.nick = n }
            status(s, .server, t("Conectado a %s como %s").f(s.cfg.host, s.nick))
            let pw = !s.cfg.password.isEmpty
            if pw && !s.saslOk && s.cfg.auth != ServerCfg.authPass {
                sendRaw(s, "PRIVMSG NickServ :IDENTIFY \(accountName(s)) \(s.cfg.password)")
                s.joinAt = TimeUtil.now() + 2200
            } else {
                s.joinAt = TimeUtil.now() + 300
            }
            // our nick was still taken by an old session: take it back
            if pw && s.cfg.auth != ServerCfg.authPass && !s.nick.eqi(s.cfg.nick) {
                sendRaw(s, s.saslOk ? "PRIVMSG NickServ :REGAIN \(s.cfg.nick)" : "PRIVMSG NickServ :REGAIN \(s.cfg.nick) \(s.cfg.password)")
                status(s, .info, t("Recuperando tu nick %s...").f(s.cfg.nick))
            }
            // private conversations that moved while we were away
            if s.capHistory {
                var since = s.chans.map { edgeTs($0, true) }.max() ?? 0
                if since <= 0 { since = TimeUtil.now() - 7 * 86_400_000 }
                sendRaw(s, "CHATHISTORY TARGETS timestamp=\(TimeUtil.iso(since)) timestamp=\(TimeUtil.iso(TimeUtil.now() + 86_400_000)) \(historyLimit(s, 50))")
            }
            IrcHooks.toast(t("%s: conectado").f(s.cfg.name))
        case 5:
            for tk in l.p.dropFirst().dropLast() {
                if tk.hasPrefix("PREFIX=(") { s.prefixes = tk.substringAfter(")") }
                else if tk.hasPrefix("ELIST=") { s.listMask = tk.dropFirst(6).uppercased().contains("M") }
                else if tk.hasPrefix("CHATHISTORY=") { s.historyMax = Int(tk.dropFirst(12)) ?? 0 }
                else if tk.hasPrefix("soju.im/FILEHOST=") {
                    let url = isupportUnescape(String(tk.dropFirst(17)))
                    if url.hasPrefix("https://") || url.hasPrefix("http://") {
                        s.filehost = url
                        status(s, .info, t("Este servidor acepta subidas de imágenes (soju FILEHOST)"))
                    }
                }
            }
        case 4, 333, 321: break
        case 2, 3, 265, 266, 375, 376: status(s, .server, last)
        case 372:
            let m = last.hasPrefix("- ") ? String(last.dropFirst(2)) : last
            status(s, .server, m.ifEmpty(" "))
        case 332:
            guard l.p.count >= 3 else { return }
            let c = getChan(s, l.p[1], .channel)
            c.topic = IrcText.strip(l.p[2])
            addMsg(s, c, .topic, nil, t("Tema: %s").f(l.p[2]))
        case 353:
            guard l.p.count >= 4, let c = findChan(s, l.p[2]) else { return }
            if !c.namesBuilding { c.users.removeAll(); c.namesBuilding = true }
            for n in l.p[3].split(separator: " ") { addUser(s, c, String(n)) }
        case 366:
            guard l.p.count >= 2, let c = findChan(s, l.p[1]) else { return }
            c.namesBuilding = false
            sortUsers(s, c)
            dirty()
        case 322:
            guard l.p.count >= 3, s.listSkip == 0 else { return }
            let users = Int(l.p[2]) ?? 0
            let e = ListedChan(name: l.p[1], users: users, topic: IrcText.strip(l.p.count > 3 ? l.p[3] : ""))
            if s.listed.count < maxListed { s.listed.append(e) }
            else if let mi = s.listed.indices.min(by: { s.listed[$0].users < s.listed[$1].users }), s.listed[mi].users < users {
                s.listed[mi] = e      // keep the biggest channels
            }
            s.listing = 1
            dirty()
        case 323:
            if s.listSkip > 0 { s.listSkip -= 1 } else {
                s.listing = 2
                s.listed.sort { $0.users > $1.users }
                dirty()
            }
        case 433:
            if s.state != .online {
                if s.nick.count < 30 { s.nick += "_" }
                sendRaw(s, "NICK \(s.nick)")
                status(s, .error, t("Nick en uso, probando %s").f(s.nick))
            } else { addMsg(s, replyChan(s), .error, nil, t("Ese nick ya está en uso")) }
        case 900: status(s, .server, last)
        case 305: s.away = false; addMsg(s, replyChan(s), .server, nil, t("Ya no estás ausente"))
        case 306: s.away = true; addMsg(s, replyChan(s), .server, nil, t("Ahora estás marcado como ausente"))
        case 903: s.saslOk = true; status(s, .server, t("Autenticación SASL correcta")); sendRaw(s, "CAP END")
        case 902, 904, 905, 906, 907:
            status(s, .error, t("SASL falló: %s").f(last))
            if num == 904 { status(s, .error, t("Revisa la cuenta y la contraseña en Servidores. Se intentará con NickServ.")) }
            sendRaw(s, "CAP END")
        default:
            // everything else: show the human-readable part
            let b = l.p.dropFirst().joined(separator: " ")
            let toView = ((300...399).contains(num) && num != 353) || (400...599).contains(num)
            addMsg(s, toView ? replyChan(s) : s.status, num >= 400 ? .error : .server, nil, b)
        }
    }

    /// ISUPPORT values escape some bytes as \xHH
    private static func isupportUnescape(_ v: String) -> String {
        var b = ""
        let cs = Array(v)
        var i = 0
        while i < cs.count {
            if cs[i] == "\\", i + 3 < cs.count, cs[i + 1] == "x", let h = UInt8(String(cs[i + 2...i + 3]), radix: 16) {
                b.append(Character(UnicodeScalar(h))); i += 4; continue
            }
            b.append(cs[i]); i += 1
        }
        return b
    }

    // MARK: - Connection threads

    private static func resetForConnect(_ s: Server, _ cfg: ServerCfg) {
        s.state = .registering
        s.nick = cfg.nick
        s.prefixes = "~&@%+"
        s.joinAt = 0
        s.probe = false
        s.outq.removeAll()
        s.capsLs = ""
        s.capSasl = false; s.saslOk = false
        s.capTags = false; s.capBatch = false; s.capHistory = false
        s.historyMax = 0; s.listMask = false; s.filehost = ""
        s.listing = 0; s.listSkip = 0
        s.batches.removeAll()
        for c in s.chans { c.histReq = .none; c.histEnd = false }
    }

    private static func serverLoop(_ s: Server) {
        let backoff = [5, 10, 20, 30, 60]
        var attempt = 0
        while true {
            if !locked({ s.wantConnect }) {
                locked { s.state = .off; dirty() }
                s.wake.lock()
                while !locked({ s.wantConnect }) { s.wake.wait() }
                s.wake.unlock()
                continue
            }
            let cfg: ServerCfg = locked {
                s.state = .connecting
                status(s, .info, t("Conectando a %s:%d%s...").f(s.cfg.host, s.cfg.port, s.cfg.ssl ? " (SSL)" : ""))
                return s.cfg
            }
            let conn: Conn
            do {
                conn = try Conn.open(host: cfg.host, port: cfg.port, ssl: cfg.ssl)
            } catch {
                let wait = backoff[min(attempt, 4)]
                attempt += 1
                locked {
                    s.state = .waiting
                    status(s, .error, t("%s. Reintento en %d s").f(connError(cfg, error), wait))
                }
                waitOrCancel(s, wait)
                continue
            }
            attempt = 0
            locked {
                s.conn = conn
                resetForConnect(s, cfg)
                s.certOk = conn.certOk
                if cfg.ssl && !conn.certOk { status(s, .info, t("Aviso: el certificado SSL del servidor no se pudo verificar")) }
                sendRaw(s, "CAP LS 302")
                if cfg.auth == ServerCfg.authPass && !cfg.password.isEmpty { sendRaw(s, "PASS \(cfg.password)") }
                sendRaw(s, "NICK \(cfg.nick)")
                let ident = String(cfg.user.ifEmpty(cfg.nick).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.lowercased().prefix(10))
                sendRaw(s, "USER \(ident.ifEmpty("vita")) 0 * :\(cfg.realname.ifEmpty("VitaIRC"))")
            }
            var lastRx = TimeUtil.now()
            var pingSent = false
            do {
                while locked({ s.wantConnect }) {
                    let out: [String] = locked { let o = s.outq; s.outq.removeAll(); return o }
                    for o in out { try conn.write(o) }
                    let now = TimeUtil.now()
                    if locked({ s.joinAt != 0 && now >= s.joinAt }) { locked { s.joinAt = 0; doAutojoin(s) }; continue }
                    if locked({ s.probe }) {
                        locked { s.probe = false; sendRaw(s, "PING :probe") }
                        lastRx = now - 225_000      // expect an answer within ~15 s
                        pingSent = true
                        continue
                    }
                    if let line = try conn.readLine() {
                        lastRx = TimeUtil.now()
                        pingSent = false
                        locked { handleLine(s, line) }
                        continue
                    }
                    if now - lastRx > 120_000 && !pingSent { locked { sendRaw(s, "PING :vitairc") }; pingSent = true }
                    if now - lastRx > 240_000 { break }
                }
                // QUIT, if one was queued
                let out: [String] = locked { let o = s.outq; s.outq.removeAll(); return o }
                for o in out { try? conn.write(o) }
            } catch {}
            conn.close()
            locked {
                s.conn = nil
                s.state = s.wantConnect ? .waiting : .off
                s.joinAt = 0
                for c in s.chans { c.joined = false; c.users.removeAll() }
                status(s, .error, t("Desconectado de %s").f(cfg.host))
            }
            if locked({ s.wantConnect }) { waitOrCancel(s, 5) }
        }
    }

    private static func connError(_ cfg: ServerCfg, _ e: Error) -> String {
        if let c = e as? ConnError {
            if c.dns { return t("No se pudo resolver %s").f(cfg.host) }
            if c.tls { return t("Error TLS: %s (-0x%04x)").f(c.message, 0).replacingOccurrences(of: " (-0x0000)", with: "") }
        }
        return t("No se pudo conectar a %s:%d").f(cfg.host, cfg.port)
    }

    private static func waitOrCancel(_ s: Server, _ seconds: Int) {
        let until = TimeUtil.now() + Int64(seconds) * 1000
        while TimeUtil.now() < until && locked({ s.wantConnect }) { Thread.sleep(forTimeInterval: 0.2) }
    }

    // MARK: - Public control

    /// Rebuilds runtime servers from Config (keeps connections whose index persists).
    public static func syncFromConfig() {
        locked {
            while servers.count > Config.servers.count {
                let s = servers.removeLast()
                s.wantConnect = false
                s.conn?.close()
            }
            for (i, cfg) in Config.servers.enumerated() {
                let s: Server
                if i < servers.count { s = servers[i] } else { s = Server(i, cfg); servers.append(s) }
                if s.chans.isEmpty { s.chans.append(Chan(nextUid, .status, cfg.name)); nextUid += 1 }
                // the live connection keeps its snapshot until reconnect
                if s.state == .off || s.state == .waiting { s.cfg = cfg }
                s.status.name = cfg.name
            }
            dirty()
        }
    }

    public static func connect(_ sidx: Int) {
        locked {
            guard sidx >= 0, sidx < servers.count else { return }
            let s = servers[sidx]
            if s.state == .off { s.cfg = Config.servers[sidx] }
            s.wantConnect = true
            s.wake.lock(); s.wake.broadcast(); s.wake.unlock()
            if s.thread == nil {
                let th = Thread { serverLoop(s) }
                th.name = "irc-\(s.idx)"
                th.qualityOfService = .userInitiated
                s.thread = th
                th.start()
            }
            dirty()
        }
    }

    public static func disconnect(_ sidx: Int, _ reason: String? = nil) {
        locked {
            guard sidx >= 0, sidx < servers.count else { return }
            let s = servers[sidx]
            if s.state == .online || s.state == .registering { sendRaw(s, "QUIT :\(reason ?? "VitaIRC for iPhone")") }
            s.wantConnect = false
            dirty()
        }
    }

    public static func quitAll() { for i in servers.indices where servers[i].wantConnect { disconnect(i) } }

    /// After the network came back or the app returned: verify that links are alive.
    public static func resumeCheck() {
        locked { for s in servers where s.state == .online || s.state == .registering { s.probe = true } }
    }

    /// Screenshot mode: a line handled as if the server sent it (never sent anywhere).
    public static func demoLine(_ sidx: Int, _ line: String) {
        locked { if sidx < servers.count { handleLine(servers[sidx], line) } }
    }

    public static func anyConnected() -> Bool { locked { servers.contains { $0.wantConnect } } }
}
