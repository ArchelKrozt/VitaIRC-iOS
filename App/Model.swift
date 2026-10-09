import SwiftUI
import UserNotifications
import VitaIRCCore

struct ReactUi: Hashable { let emoji: String; let count: Int; let mine: Bool }

struct MsgUi: Identifiable, Equatable {
    let id: Int64
    let type: MsgType
    let nick: String
    let text: String
    let spans: [FmtSpan]
    let selfMsg: Bool
    let time: String
    let ts: Int64
    let highlight: Bool
    let pending: Bool
    let trans: String?
    let transState: TransState
    let reacts: [ReactUi]
    let canReact: Bool
    var chatty: Bool { type == .msg || type == .action || type == .notice }
}

struct WinUi: Identifiable, Hashable {
    let sidx: Int
    let uid: Int64
    let type: ChanType
    let name: String
    let unread: Int
    let mention: Int
    let joined: Bool
    let muted: Bool
    let serverState: ServerState
    var id: String { "\(sidx)/\(uid)" }
}

struct UserUi: Identifiable, Hashable { let nick: String; let prefix: Character?; let away: Bool; var id: String { nick } }

struct ChanUi: Equatable {
    let sidx: Int, uid: Int64
    let type: ChanType
    let name: String
    let topic: String
    let users: [UserUi]
    let joined: Bool, transIn: Bool, transOut: Bool
    let transLang: String
    let muted: Bool
    let loadingOlder: Bool
    let msgs: [MsgUi]
    let draft: String
    let serverName: String, host: String, nick: String
    let state: ServerState
    let away: Bool
    let myPrefix: Character?
    let canHistory: Bool
    let listMask: Bool
}

/// Immutable copies of the IRC state for SwiftUI, rebuilt after changes (at most ~20 times a second).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var windows: [WinUi] = []
    @Published var chan: ChanUi?
    @Published var toast: String?
    @Published var busy = ""
    @Published var update: UpdateInfo?
    @Published var booru = BooruState()
    @Published var favorites: [BPost] = []
    @Published var draftOverride: (String, Int64, String)?   // (window id, nonce, text) put into the input
    @Published var jump: (Int64, Int64)?                     // window uid, message id to show
    @Published var revision: Int64 = 0

    private var pending = false
    private var toastTask: Task<Void, Never>?

    /// Called from any thread by the core
    nonisolated func changed() {
        Task { @MainActor in
            if self.pending { return }
            self.pending = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.pending = false
            self.rebuild()
        }
    }

    func rebuild() {
        Irc.locked {
            var wins: [WinUi] = []
            for (i, s) in Irc.servers.enumerated() where i < Config.servers.count {
                for c in s.chans {
                    wins.append(WinUi(sidx: i, uid: c.uid, type: c.type, name: c.type == .status ? Config.servers[i].name : c.name,
                                      unread: c.unread, mention: c.mention, joined: c.joined, muted: c.muted, serverState: s.state))
                }
            }
            windows = wins
            if Irc.viewSidx >= 0, Irc.viewSidx < Irc.servers.count, let c = Irc.findChanUid(Irc.servers[Irc.viewSidx], Irc.viewUid) {
                let s = Irc.servers[Irc.viewSidx]
                chan = ChanUi(sidx: s.idx, uid: c.uid, type: c.type, name: c.name, topic: c.topic,
                              users: c.users.map { UserUi(nick: $0.nick, prefix: $0.prefix, away: $0.away) },
                              joined: c.joined, transIn: c.transIn, transOut: c.transOut, transLang: c.transLang, muted: c.muted,
                              loadingOlder: c.histReq == .before,
                              msgs: c.msgs.map { m in
                                  MsgUi(id: m.id, type: m.type, nick: m.nick, text: m.text, spans: m.spans, selfMsg: m.selfMsg, time: m.time,
                                        ts: m.ts, highlight: m.highlight, pending: m.pending, trans: m.trans, transState: m.transState,
                                        reacts: (m.reacts ?? []).map { ReactUi(emoji: $0.emoji, count: $0.count, mine: $0.mine) },
                                        canReact: Irc.canReact(s, m))
                              },
                              draft: c.draft, serverName: Config.servers.indices.contains(s.idx) ? Config.servers[s.idx].name : s.cfg.name,
                              host: s.cfg.host, nick: s.nick.ifEmpty(s.cfg.nick), state: s.state, away: s.away,
                              myPrefix: Irc.myPrefix(s, c), canHistory: s.capHistory, listMask: s.listMask)
            } else { chan = nil }
            // requests from the network side
            if let (si, u) = Irc.focusReq { Irc.focusReq = nil; DispatchQueue.main.async { self.select(si, u) } }
            if let (si, ch) = Irc.invite {
                Irc.invite = nil
                DispatchQueue.main.async { UiState.shared.invite = (si, ch) }
            }
            // keep a valid window on screen
            if chan == nil, let w = wins.first { DispatchQueue.main.async { self.select(w.sidx, w.uid) } }
        }
        booru = Booru.state
        favorites = Booru.favorites
        revision += 1
    }

    /// Shows a window (and clears its counters and notifications).
    func select(_ sidx: Int, _ uid: Int64) {
        Irc.locked {
            Irc.viewSidx = sidx
            Irc.viewUid = uid
            if sidx >= 0, sidx < Irc.servers.count, let c = Irc.findChanUid(Irc.servers[sidx], uid) { c.unread = 0; c.mention = 0 }
            Irc.dirty()
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(sidx)/\(uid)"])
        UiState.shared.showChat = true
    }

    func showToast(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(nanoseconds: 3_200_000_000); if !Task.isCancelled { toast = nil } }
    }

    /// Puts text into a window's input (a quick reply, a mention, an uploaded link).
    func appendToInput(_ sidx: Int, _ uid: Int64, _ text: String, replace: Bool = false) {
        var newDraft = text
        Irc.locked {
            if sidx < Irc.servers.count, let c = Irc.findChanUid(Irc.servers[sidx], uid) {
                c.draft = replace || c.draft.isBlank ? text : c.draft.trimmed + " " + text
                newDraft = c.draft
            }
        }
        select(sidx, uid)
        draftOverride = ("\(sidx)/\(uid)", Int64(Date().timeIntervalSince1970 * 1000), newDraft)
        UiState.shared.closeAll()
    }

    func saveDraft(_ sidx: Int, _ uid: Int64, _ text: String) {
        Irc.locked { if sidx < Irc.servers.count { Irc.findChanUid(Irc.servers[sidx], uid)?.draft = text } }
    }

    /// Runs a block on the live channel object
    func withChan(_ c: ChanUi, _ f: (Server, Chan) -> Void) {
        Irc.locked {
            guard c.sidx < Irc.servers.count, let ch = Irc.findChanUid(Irc.servers[c.sidx], c.uid) else { return }
            f(Irc.servers[c.sidx], ch)
            History.saveSession()
            Irc.dirty()
        }
    }
}

/// Which sheets and screens are open (one place, so a notification or a link can open them).
@MainActor
final class UiState: ObservableObject {
    static let shared = UiState()
    @Published var showChat = true                 // iPhone: chat pushed over the window list
    @Published var sheet: Sheet?
    @Published var image: ImageTarget?
    @Published var video: VideoTarget?
    @Published var invite: (Int, String)?
    @Published var updateAsked = ""
    @Published var choose: ChooseAsk?
    @Published var msgSheet: MsgUi?
    @Published var chanListQuery = ""

    enum Sheet: Identifiable, Equatable {
        case servers, settings, chanList, booru, help, users, quick, uploads, links, editServer(Int)
        var id: String { "\(self)" }
    }

    func closeAll() { sheet = nil; image = nil; video = nil }
}

struct ImageTarget: Identifiable, Equatable { let id = UUID(); let url: String; let page: String; let post: BPost? }
struct VideoTarget: Identifiable, Equatable { let id = UUID(); let url: String; let page: String }

enum Actions {
    @MainActor static func browser(_ url: String) {
        if let u = URL(string: url) { UIApplication.shared.open(u) }
    }

    /// Opens a link the best way the app can: viewer, player or browser.
    @MainActor static func openLink(_ url: String) {
        let p = Previews.cached(url)
        switch p?.kind ?? Previews.kindOf(url) {
        case .image: UiState.shared.image = ImageTarget(url: p?.media.nonEmptyOrNil ?? Previews.imageUrl(url) ?? url, page: url, post: nil)
        case .video where ["webm", "mkv"].contains(url.substringBefore("?").substringAfterLast(".").lowercased()):
            browser(url)        // iOS plays MP4/MOV, not WebM
        case .video: UiState.shared.video = VideoTarget(url: p?.media.nonEmptyOrNil ?? Previews.videoUrl(url), page: url)
        case .page: browser(url)
        }
    }

    /// Window that gets the link of an upload: the open one, unless it's the server window.
    @MainActor static func uploadTarget() -> (Int, Int64)? {
        guard let c = AppModel.shared.chan, c.type != .status else { return nil }
        return (c.sidx, c.uid)
    }
}

extension String { var nonEmptyOrNil: String? { isEmpty ? nil : self } }
