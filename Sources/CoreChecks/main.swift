// Checks of the IRC core: `swift run CoreChecks` (VITAIRC_LIVE=1 also connects to Libera.Chat).
// A plain program instead of XCTest/Swift Testing, so it runs with the Command Line Tools too.
import Foundation
@testable import VitaIRCCore

/// The same cases as VitaIRC for Android's IrcTest.
struct IrcTests {
    let s: Server
    let dir: URL

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitairc-\(UUID().uuidString)")
        Config.setup(dir: dir)
        var cfg = ServerCfg(); cfg.name = "soju"; cfg.host = "bnc.example"; cfg.nick = "me"; cfg.channels = ""
        Config.servers = [cfg]
        Config.sound = true
        Config.ignore = ""
        Config.highlight = ""
        Irc.servers.removeAll()
        Irc.syncFromConfig()
        s = Irc.servers[0]
        s.nick = "me"
        s.state = .registering
        Irc.viewSidx = 0
        Irc.viewUid = s.status.uid
        IrcHooks.notify = { _, _, _ in }
    }

    func feed(_ line: String) { Irc.locked { Irc.handleLine(s, line) } }
    func outHas(_ needle: String) -> Bool { s.outq.contains { $0.contains(needle) } }
    func outClear() { s.outq.removeAll() }

    func textHelpers() {
        let f = IrcText.parse("\u{02}hi\u{02} \u{03}04,01red\u{0F} done")
        check(f.text == "hi red done")
        check(!f.spans.isEmpty)
        check(IrcText.containsWord("hola me", "me"))
        check(!IrcText.containsWord("meme", "me"))
        check(IrcText.globMatch("spam*", "SpamBot"))
        check(IrcText.urls("see https://a.org/x.png.") == ["https://a.org/x.png"])
        check(TimeUtil.parseIso("2026-10-07T23:30:00.000Z") == 1791415800000)
        check(TimeUtil.iso(1791415800000) == "2026-10-07T23:30:00.000Z")
        check(Irc.splitText("a b") == ["a b"])
        check(Irc.splitText(String(repeating: "x", count: 900)).allSatisfy { $0.utf8.count <= 380 })
        check(Irc.splitText(String(repeating: "ñ", count: 400)).allSatisfy { $0.utf8.count <= 380 })
        check(Line.unescape("a\\:b\\sc") == "a;b c")
        check(Line.escape("x y;z") == "x\\sy\\:z")
        check("%s tiene %d (%.1f MB) %02d %%".f("ana", 3, 1.25, 7) == "ana tiene 3 (1.2 MB) 07 %" || "%s tiene %d (%.1f MB) %02d %%".f("ana", 3, 1.25, 7) == "ana tiene 3 (1.3 MB) 07 %")
        check("--- %.2s/%.2s ---".f("0912", "10xx") == "--- 09/10 ---")
        let l = Line("@time=2026-10-07T23:30:00.000Z;msgid=a\\sb :nick!u@h PRIVMSG #c :hola  mundo")
        check(l.nick == "nick" && l.cmd == "PRIVMSG" && l.p == ["#c", "hola  mundo"] && l.tags["msgid"] == "a b")
    }

    func capsHistoryReactionsQueue() {
        feed(":srv CAP * LS :server-time batch message-tags draft/chathistory sasl multi-prefix")
        check(outHas("CAP REQ :server-time multi-prefix batch message-tags draft/chathistory"))
        outClear()
        feed(":srv CAP me ACK :server-time multi-prefix batch message-tags draft/chathistory")
        check(s.capTags && s.capBatch && s.capHistory)
        check(outHas("CAP END"))
        outClear()
        feed(":srv 005 me CHATHISTORY=1000 ELIST=CMNTU soju.im/FILEHOST=https://bnc.example/uploads\\x3Dx :are supported")
        check(s.historyMax == 1000)
        check(s.listMask)
        check(s.filehost == "https://bnc.example/uploads=x")

        // offline queue
        s.state = .waiting
        let c = Irc.locked { Irc.getChan(s, "#vita", .channel) }
        Irc.userInput(0, c.uid, "hola desde el metro")
        Irc.userInput(0, c.uid, "/me saluda")
        check(s.offq.count == 2)
        check(c.msgs.last!.pending)
        s.state = .registering
        feed(":srv 001 me :Welcome")
        check(s.state == .online)
        check(outHas("CHATHISTORY TARGETS timestamp="))
        outClear()
        feed(":me!u@h JOIN #vita")
        check(outHas("CHATHISTORY LATEST #vita * 100"))
        check(outHas("PRIVMSG #vita :hola desde el metro"))
        check(outHas("PRIVMSG #vita :\u{01}ACTION saluda\u{01}"))
        check(s.offq.isEmpty)
        check(!c.msgs.contains { $0.pending })
        outClear()

        // history batch, out of order, with a duplicate and a CTCP that must not be answered
        feed(":srv BATCH +h1 chathistory #vita")
        feed("@batch=h1;time=2026-10-07T23:50:00.000Z;msgid=a2 :bob!u@h PRIVMSG #vita :segundo")
        feed("@batch=h1;time=2026-10-07T12:00:00.000Z;msgid=a1 :ann!u@h PRIVMSG #vita :primero me")
        feed("@batch=h1;time=2026-10-08T15:00:00.000Z;msgid=a3 :me!u@h PRIVMSG #vita :mío")
        feed("@batch=h1;time=2026-10-08T15:00:00.000Z;msgid=a3 :me!u@h PRIVMSG #vita :mío")
        feed("@batch=h1;time=2026-10-08T15:01:00.000Z :ann!u@h PRIVMSG me :\u{01}VERSION\u{01}")
        check(s.outq.isEmpty)
        feed(":srv BATCH -h1")
        check(c.histReq == .none)
        let real = c.msgs.filter { $0.type != .date }
        check(zip(real, real.dropFirst()).allSatisfy { $0.ts <= $1.ts })
        check(Set(c.msgs.map { $0.id }).count == c.msgs.count)
        check(c.findMsgId("a1")!.highlight)
        check(c.findMsgId("a3")!.selfMsg)
        check(c.mention == 1)
        check(c.msgs.first!.type == .date)

        // same batch again: nothing added
        let n = c.msgs.count
        feed(":srv BATCH +h2 chathistory #vita")
        feed("@batch=h2;time=2026-10-07T12:00:00.000Z;msgid=a1 :ann!u@h PRIVMSG #vita :primero me")
        feed(":srv BATCH -h2")
        check(c.msgs.count == n)

        // older page
        check(Irc.locked { Irc.requestOlder(s, c) })
        check(outHas("CHATHISTORY BEFORE #vita timestamp=2026-10-07T12:00:00.000Z 50"))
        check(!Irc.locked { Irc.requestOlder(s, c) })
        outClear()
        let mentions = c.mention
        feed(":srv BATCH +h3 chathistory #vita")
        feed("@batch=h3;time=2026-10-05T10:00:00.000Z;msgid=z1 :old!u@h PRIVMSG #vita :muy viejo me")
        feed(":srv BATCH -h3")
        check(c.msgs[1].msgid == "z1")
        check(c.mention == mentions)
        Irc.locked { Irc.requestOlder(s, c) }
        feed(":srv BATCH +h4 chathistory #vita")
        feed(":srv BATCH -h4")
        check(c.histEnd)

        // TARGETS: queries yes, services no
        outClear()
        feed(":srv BATCH +t1 draft/chathistory-targets")
        feed("@batch=t1 :srv CHATHISTORY TARGETS bob 2026-10-08T15:00:00.000Z")
        feed("@batch=t1 :srv CHATHISTORY TARGETS NickServ 2026-10-08T15:00:00.000Z")
        feed(":srv BATCH -t1")
        check(Irc.findChan(s, "bob")?.type == .query)
        check(Irc.findChan(s, "NickServ") == nil)
        check(outHas("CHATHISTORY LATEST bob * 100"))

        // my message from another client goes to the query; STATUSMSG
        feed("@time=2026-10-08T16:00:00.000Z;msgid=q1 :me!u@h PRIVMSG carol :hola carol")
        check(Irc.findChan(s, "carol")!.msgs.last!.selfMsg)
        feed(":op!u@h PRIVMSG @#vita :solo ops")
        check(c.msgs.last!.text == "solo ops")

        // reactions
        let m = c.findMsgId("a2")!
        feed("@+draft/react=👍;+draft/reply=a2 :ann!u@h TAGMSG #vita")
        feed("@+draft/react=👍;+draft/reply=a2 :ann!u@h TAGMSG #vita")
        feed("@+draft/react=👍;+draft/reply=a2 :bob!u@h TAGMSG #vita")
        feed("@+draft/react=❤️;+draft/reply=a2 :bob!u@h TAGMSG #vita")
        check(m.reacts!.count == 2)
        check(m.reacts![0].count == 2)
        feed("@+draft/unreact=👍;+draft/reply=a2 :ann!u@h TAGMSG #vita")
        check(m.reacts![0].count == 1)
        outClear()
        Irc.locked { Irc.sendReact(s, c, m, "🔥") }
        check(outHas("@+draft/react=🔥;+draft/reply=a2 TAGMSG #vita"))
        Irc.locked { Irc.sendReact(s, c, m, "🔥") }
        check(outHas("@+draft/unreact=🔥;+draft/reply=a2 TAGMSG #vita"))

        // mute: counted, no notification
        nonisolated(unsafe) var notified = 0
        IrcHooks.notify = { _, _, _ in notified += 1 }
        c.muted = true
        feed("@time=2026-10-08T18:00:00.000Z :ann!u@h PRIVMSG #vita :oye me")
        check(notified == 0)
        c.muted = false
        feed("@time=2026-10-08T18:01:00.000Z :ann!u@h PRIVMSG #vita :oye me otra vez")
        check(notified == 1)
        IrcHooks.notify = { _, _, _ in }

        // /list with a mask, and a search sent while the full list still arrives
        outClear()
        Irc.userInput(0, s.status.uid, "/list *vita*")
        check(outHas("LIST *vita*\r\n"))
        feed(":srv 323 me :End of /LIST")
        Irc.userInput(0, s.status.uid, "/list")
        feed(":srv 322 me #big 900 :big channel")
        Irc.userInput(0, s.status.uid, "/list *vita*")
        feed(":srv 322 me ##uk 11 :an invitation")
        feed(":srv 323 me :End of /LIST")
        check(s.listing == 1)
        feed(":srv 322 me #vitasdk 8 :Vita homebrew")
        feed(":srv 323 me :End of /LIST")
        check(s.listing == 2)
        check(s.listed.map { $0.name } == ["#vitasdk"])

        // back in the app: an online link is probed, a waiting one reconnects at once
        s.wantConnect = true
        s.state = .online
        Irc.resumeCheck()
        check(s.probe && !s.reconnectNow)
        s.probe = false
        s.state = .waiting
        Irc.resumeCheck()
        check(s.reconnectNow && !s.probe)
        s.reconnectNow = false
        s.wantConnect = false
        s.state = .online

        // the ring keeps maxMsgs
        for i in 0..<(Irc.maxMsgs + 20) { feed(":ann!u@h PRIVMSG #vita :spam \(i)") }
        check(c.msgs.count == Irc.maxMsgs)
    }

    func selfMessageKeepsWholeText() {
        s.state = .online
        let url = "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/Fronalpstock_big.jpg/640px-Fronalpstock_big.jpg"
        Irc.userInput(0, s.status.uid, "/msg me look \(url)")
        check(outHas("PRIVMSG me :look \(url)"))
        feed(":me!u@h PRIVMSG me :look \(url)")
        let q = Irc.findChan(s, "me")!
        check(q.msgs.filter { $0.text == "look \(url)" }.count == 1)
    }

    func historyRoundTrip() throws {
        s.state = .online
        let logDir = dir.appendingPathComponent("logs/bnc.example")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try "2026-10-06\t21:15\t0\t0\tolduser\tlinea de la version 1.0\n".write(to: logDir.appendingPathComponent("#vita.log"), atomically: true, encoding: .utf8)
        let c = Irc.locked { Irc.getChan(s, "#vita", .channel) }
        check(c.msgs.first { $0.nick == "olduser" }?.time == "21:15")
        feed("@time=2026-10-07T23:30:00.000Z;msgid=m-1 :ann!u@h PRIVMSG #vita :mensaje con msgid")
        Irc.locked { Irc.closeChan(s, c) }
        let logText = try String(contentsOf: logDir.appendingPathComponent("#vita.log"), encoding: .utf8)
        let last = logText.split(separator: "\n").last!
        check(last.hasSuffix("\tann\tmensaje con msgid\t1791415800000\tm-1"))
        let c2 = Irc.locked { Irc.getChan(s, "#vita", .channel) }
        check(c2.findMsgId("m-1")?.ts == 1791415800000)
        check(c2.msgs.last?.type == .info)
        c2.muted = true
        History.saveSession()
        let session = try String(contentsOf: dir.appendingPathComponent("session.txt"), encoding: .utf8)
        check(session.contains("#vita\t\t1"))
    }

    func configRoundTrip() throws {
        try "translator=1\nopenai_key=sk-x\n[server]\nname=Bnc\nhost=b.example\nport=6697\nssl=1\nnick=ana\nchannels=#a,#b\n".write(to: Config.file, atomically: true, encoding: .utf8)
        Config.load()
        check(Config.trProvider == Config.trpOpenAI && Config.servers.count == 1 && Config.servers[0].nick == "ana")
        Config.save()
        Config.load()
        check(Config.servers[0].channels == "#a,#b" && Config.openaiKey == "sk-x")
    }
}

/// Connects to Libera.Chat for real. Does something only with VITAIRC_LIVE=1 (needs the network).
struct LiveTests {
    private func waitFor(_ secs: Double, _ cond: () -> Bool) {
        let until = Date().addingTimeInterval(secs)
        while !cond() && Date() < until { Thread.sleep(forTimeInterval: 0.3) }
    }

    func connectsSearchesAndDisconnects() {
        guard ProcessInfo.processInfo.environment["VITAIRC_LIVE"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitairc-live-\(UUID().uuidString)")
        Config.setup(dir: dir)
        var cfg = ServerCfg(); cfg.nick = "vtest\(Int.random(in: 1000..<9999))"; cfg.channels = ""
        Config.servers = [cfg]
        Irc.servers.removeAll()
        Irc.syncFromConfig()
        Irc.connect(0)
        let s = Irc.servers[0]
        waitFor(40) { Irc.locked { s.state == .online && s.joinAt == 0 } }
        check(Irc.locked { s.state } == .online)
        check(Irc.locked { s.certOk })
        check(Irc.locked { s.listMask })
        Irc.userInput(0, s.status.uid, "/list *vitasdk*")
        waitFor(30) { Irc.locked { s.listing == 2 } }
        check(Irc.locked { s.listed.contains { $0.name == "#vitasdk" } })
        Irc.disconnect(0)
        waitFor(15) { Irc.locked { s.state == .off } }
        check(Irc.locked { s.state } == .off)
        print("LIVE status lines:", Irc.locked { s.status.msgs.count }, "first:", Irc.locked { s.status.msgs.first?.text ?? "" })
    }
}


/// Network services against the real sites (VITAIRC_LIVE=1).
struct ServiceChecks {
    func run() throws {
        guard ProcessInfo.processInfo.environment["VITAIRC_LIVE"] == "1" else { return }
        let yt = try Previews.fetch("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        check(yt.ok && yt.videoSite && yt.title.contains("Rick Astley") && !yt.image.isEmpty)
        let gh = try Previews.fetch("https://github.com/ArchelKrozt/VitaIRC")
        check(gh.ok && gh.title.contains("VitaIRC") && gh.image.hasPrefix("https://"))
        let img = try Previews.fetch("https://upload.wikimedia.org/wikipedia/commons/3/3f/Fronalpstock_big.jpg")
        check(img.ok && img.kind == .image)
        let vid = try Previews.fetch("https://www.w3schools.com/html/mov_bbb.mp4")
        check(vid.ok && vid.kind == .video && vid.size > 500_000)
        print("LIVE previews:", yt.title, "|", gh.title, "| video", vid.size)
        Config.trProvider = Config.trpGoogle
        let es = try Translator.translate("Good evening, how are you?", "es", false)
        check(es.lowercased().contains("buenas"))
        let same = try Translator.translate("hola, ¿cómo estás?", "es", false)
        check(same.isEmpty)
        print("LIVE translation:", es)
        let sb = try Http.call(Booru.searchUrl(Booru.safebooru, "scenery cat", false, 0, ""))
        let sbp = Booru.parse(Booru.safebooru, sb.body, false)
        check(sb.ok && !sbp.posts.isEmpty && sbp.posts.allSatisfy { $0.rating == "g" })
        let sk = try Http.call(Booru.searchUrl(Booru.sankaku, "scenery cat", false, 0, ""),
                               headers: ["Accept": "application/vnd.sankaku.api+json;v=2", "Origin": "https://sankaku.app"], ua: "Mozilla/5.0")
        let skp = Booru.parse(Booru.sankaku, sk.body, false)
        check(sk.ok && !skp.posts.isEmpty)
        print("LIVE booru: safebooru \(sbp.posts.count), sankaku \(skp.posts.count)")
    }
}

/// Replies, profiles over IRC, WHOIS cards and image authors.
struct NewFeatureChecks {
    func run() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitairc-nf-\(UUID().uuidString)")
        Config.setup(dir: dir)
        var cfg = ServerCfg(); cfg.host = "bnc.example"; cfg.nick = "me"; cfg.channels = ""
        Config.servers = [cfg]
        Irc.servers.removeAll()
        Irc.syncFromConfig()
        let s = Irc.servers[0]
        s.nick = "me"; s.state = .online; s.capTags = true
        func feed(_ l: String) { Irc.locked { Irc.handleLine(s, l) } }
        func out(_ needle: String) -> Bool { s.outq.contains { $0.contains(needle) } || s.slowq.contains { $0.contains(needle) } }

        // replies: received with the tag, sent with it
        let c = Irc.locked { Irc.getChan(s, "#vita", .channel) }
        feed("@msgid=m1 :ana!u@h PRIVMSG #vita :¿alguien probó la 1.4?")
        feed("@msgid=m2;+draft/reply=m1 :bob!u@h PRIVMSG #vita :sí, funciona")
        check(c.findMsgId("m2")?.replyTo == "m1")
        Irc.userInput(0, c.uid, "a mí también", replyTo: "m1")
        check(out("@+draft/reply=m1 PRIVMSG #vita :a mí también"))
        check(c.msgs.last?.replyTo == "m1" && c.msgs.last?.selfMsg == true)
        s.capTags = false; s.outq.removeAll()
        Irc.userInput(0, c.uid, "sin etiquetas", replyTo: "m1")
        check(out("PRIVMSG #vita :sin etiquetas") && !out("@+draft"))
        s.capTags = true; s.outq.removeAll()

        // my profile answers a request, paced, and another app reads it back
        MyProfile.name = "Diego"
        MyProfile.bio = "Fan de la Vita 🎮. Programo homebrew y juego en línea con amigos, hablando de todo un poco." + String(repeating: " más texto", count: 15)
        MyProfile.share = true
        try Data((0..<2500).map { UInt8($0 % 251) }).write(to: MyProfile.avatarFile)
        let fav = BPost(engine: 1, id: "123", rating: "g", w: 10, h: 10, ext: "jpg", fileSize: 1, thumbUrl: "https://cdn.donmai.us/t.jpg", viewUrl: "v", fileUrl: "f", tags: "cat")
        Booru.toggleFav(fav, thumb: nil)
        MyProfile.setPublic(fav.key, true)
        feed(":ana!u@h PRIVMSG me :\u{01}VPROFILE\u{01}")
        let answer = s.slowq
        check(answer.first?.hasPrefix("NOTICE ana :\u{01}VPROFILE BEGIN 1") == true && answer.last?.contains("VPROFILE END") == true)
        check(answer.allSatisfy { $0.utf8.count <= 512 })
        feed(":ana!u@h PRIVMSG me :\u{01}VPROFILE\u{01}")
        check(s.slowq.count == answer.count)                      // once every 30 s
        // the same lines as another app receives them
        nonisolated(unsafe) var got: Profile?
        IrcHooks.profile = { _, _, p in got = p }
        Irc.requestProfile(0, "diego")
        check(out("PRIVMSG diego :\u{01}VPROFILE\u{01}"))
        for l in answer {
            let body = l.substringAfter(":").trimmingCharacters(in: .newlines)
            feed(":diego!u@h NOTICE me :" + body)
        }
        check(got?.name == "Diego" && got?.bio.hasPrefix("Fan de la Vita 🎮.") == true && got?.avatar.count == 2500)
        check(got?.favs.first?.id == "123" && got?.favs.first?.thumb == "https://cdn.donmai.us/t.jpg")
        check(Irc.findChan(s, "diego") == nil && !s.status.msgs.contains { $0.text.contains("VPROFILE") })
        MyProfile.share = false
        s.profileAnswered.removeAll(); s.slowq.removeAll()
        feed(":ana!u@h PRIVMSG me :\u{01}VPROFILE\u{01}")
        check(s.slowq.count == 1 && s.slowq[0].contains("VPROFILE NONE"))
        // pacing: 3 lines at once, then one every 800 ms
        s.slowq = (0..<6).map { "NOTICE x :\($0)\r\n" }

        // WHOIS as a card
        nonisolated(unsafe) var card: WhoisInfo?
        IrcHooks.whois = { _, w in card = w }
        Irc.whois(0, "ana")
        let before = s.status.msgs.count
        feed(":srv 311 me ana ~ana host.example * :Ana López")
        feed(":srv 319 me ana :@#vita #henkaku")
        feed(":srv 312 me ana tantalum.libera.chat :Libera")
        feed(":srv 317 me ana 125 1791415800 :seconds idle, signon time")
        feed(":srv 330 me ana anaacct :is logged in as")
        feed(":srv 671 me ana :is using a secure connection")
        feed(":srv 318 me ana :End of /WHOIS list.")
        check(card?.realname == "Ana López" && card?.channels == ["@#vita", "#henkaku"] && card?.idleSecs == 125 && card?.account == "anaacct" && card?.secure == true)
        check(s.status.msgs.count == before)
        Irc.whois(0, "ghost")
        feed(":srv 401 me ghost :No such nick/channel")
        check(card?.nick == "ghost" && card?.found == false)

        // image authors
        let dan = Booru.parse(Booru.danbooru, Data(#"[{"id":7,"rating":"g","image_width":1,"image_height":1,"file_ext":"png","file_size":5,"preview_file_url":"https://t","large_file_url":"https://l","file_url":"https://f","tag_string":"cat","tag_string_artist":"foo_bar banned_artist"}]"#.utf8), false)
        check(dan.posts.first?.artist == "foo bar")
        check(Booru.chatText("https://f", dan.posts[0]) == "https://f 🎨 foo bar")
        let sk = Booru.parse(Booru.sankaku, Data(#"{"data":[{"id":"9","rating":"s","width":1,"height":1,"file_ext":"jpg","file_size":5,"sample_url":"https://s","file_url":"https://f","tags":[{"tagName":"cat","type":0},{"tagName":"some_artist","type":1}]}],"meta":{"next":null}}"#.utf8), false)
        check(sk.posts.first?.artist == "some artist")
        Booru.loadFavorites()
        check(Booru.favorites.first?.key == "1/123")
        IrcHooks.profile = { _, _, _ in }; IrcHooks.whois = { _, _ in }
    }
}

// MARK: - runner

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var current = ""

func check(_ ok: @autoclosure () -> Bool, _ file: String = #fileID, _ line: Int = #line) {
    if !ok() { failures += 1; print("✘ \(current): check failed at line \(line)") }
}

func run(_ name: String, _ body: () throws -> Void) {
    current = name
    do { try body() } catch { failures += 1; print("✘ \(name): \(error)") }
    print("· \(name)")
}

run("textHelpers") { IrcTests().textHelpers() }
run("capsHistoryReactionsQueue") { IrcTests().capsHistoryReactionsQueue() }
run("selfMessageKeepsWholeText") { IrcTests().selfMessageKeepsWholeText() }
run("historyRoundTrip") { try IrcTests().historyRoundTrip() }
run("configRoundTrip") { try IrcTests().configRoundTrip() }
run("newFeatures") { try NewFeatureChecks().run() }
run("live") { LiveTests().connectsSearchesAndDisconnects() }
run("services") { try ServiceChecks().run() }
print(failures == 0 ? "ALL CORE CHECKS PASSED" : "\(failures) CHECKS FAILED")
exit(failures == 0 ? 0 : 1)
