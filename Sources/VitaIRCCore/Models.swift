import Foundation

public enum MsgType: Int, CaseIterable { case msg, action, notice, join, part, quit, kick, topic, server, error, info, nick, mode, date }
public enum ChanType { case status, channel, query }
public enum TransState { case none, pending, done, skip }
public enum ServerState { case off, connecting, registering, online, waiting }
/// IRCv3 chathistory request in flight for a window
public enum HistReq { case none, latest, before }

/// A reaction (IRCv3 +draft/react) shown under a message.
public final class React {
    public let emoji: String
    public var count = 0
    public var mine = false
    var who = Set<String>()         // lowercase nicks that reacted
    init(_ e: String) { emoji = e }
}

public final class Msg {
    public var id: Int64
    public let type: MsgType
    public let nick: String
    public let text: String         // without mIRC control codes
    public let spans: [FmtSpan]
    public let selfMsg: Bool
    public var ts: Int64            // ms since 1970 (UTC)
    public let msgid: String?
    public var time: String
    public var highlight = false
    public var pending = false      // typed offline, waiting to be sent
    public var trans: String?
    public var transState = TransState.none
    public var reacts: [React]?

    init(_ id: Int64, _ type: MsgType, _ nick: String, _ text: String, _ spans: [FmtSpan], _ selfMsg: Bool, _ ts: Int64, _ msgid: String?) {
        self.id = id; self.type = type; self.nick = nick; self.text = text; self.spans = spans
        self.selfMsg = selfMsg; self.ts = ts; self.msgid = msgid; self.time = TimeUtil.hhmm(ts)
    }

    public var chatty: Bool { type == .msg || type == .action || type == .notice }
}

public final class ChanUser {
    public var nick: String
    public var prefix: Character?
    public var away = false
    init(_ n: String, _ p: Character?) { nick = n; prefix = p }
}

public final class Chan {
    public let uid: Int64
    public let type: ChanType
    public var name: String
    public var msgs: [Msg] = []     // oldest first, at most Irc.maxMsgs
    var nextId: Int64 = 0
    public var topic = ""
    public var joined = false
    public var unread = 0
    public var mention = 0
    public var users: [ChanUser] = []
    var namesBuilding = false
    public var transIn = false
    public var transOut = false
    public var transLang = ""       // per-channel translation language ("" = global)
    public var muted = false
    var lastYmd = 0
    public var histReq = HistReq.none
    var histReqAt: Int64 = 0
    var histSince: Int64 = 0
    public var histEnd = false
    public var draft = ""
    var log: FileHandle?

    init(_ uid: Int64, _ type: ChanType, _ name: String) { self.uid = uid; self.type = type; self.name = name }

    public func findMsg(_ id: Int64) -> Msg? { msgs.first { $0.id == id } }
    public func findMsgId(_ msgid: String?) -> Msg? {
        guard let m = msgid, !m.isEmpty else { return nil }
        return msgs.last { $0.msgid == m }
    }
}

public struct ListedChan { public let name: String; public let users: Int; public let topic: String }

struct OfflineMsg { let chanUid: Int64; let msgId: Int64; let action: Bool; let text: String }

public struct ServerCfg: Equatable {
    public var name = "Libera.Chat"
    public var host = "irc.libera.chat"
    public var port = 6697
    public var ssl = true
    public var nick = ""
    public var user = ""            // account / auth username (defaults to nick)
    public var realname = "VitaIRC user"
    public var password = ""
    public var auth = ServerCfg.authAuto
    public var channels = "#vitasdk"
    public var autoconnect = true

    public init() {}

    public static let authAuto = 0
    public static let authNickServ = 1
    public static let authSasl = 2
    public static let authPass = 3
    public static func authName(_ a: Int) -> String? {
        switch a {
        case authNickServ: return "NickServ IDENTIFY"
        case authSasl: return "SASL PLAIN"
        case authPass: return "Server PASS"
        default: return nil
        }
    }
}
