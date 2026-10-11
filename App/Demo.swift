import SwiftUI
import VitaIRCCore

/// VITAIRC_DEMO=1: walks through the screens by itself so the build can take screenshots
/// (tools/screenshots.sh reads the step from Documents/demo_step.txt). The messages it adds
/// are local only: nothing is sent to the network.
@MainActor
enum Demo {
    /// Writes the step and waits until the screenshot script took it (demo_ack.txt), at most 40 s.
    static func step(_ name: String) async {
        let f = Config.dir.appendingPathComponent("demo_step.txt")
        let ack = Config.dir.appendingPathComponent("demo_ack.txt")
        try? name.write(to: f, atomically: true, encoding: .utf8)
        if name == "done" { return }
        for _ in 0..<200 {
            if (try? String(contentsOf: ack, encoding: .utf8))?.trimmed == name { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Diagnostics of the demo run (tools/screenshots.sh copies it next to the screenshots)
    nonisolated static func log(_ s: String) {
        let f = Config.dir.appendingPathComponent("demo_log.txt")
        let line = s + "\n"
        if let h = try? FileHandle(forWritingTo: f) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }

    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// A message from someone else, as if it came from the server (only in this window, never sent).
    static func fake(_ sidx: Int, _ line: String) { Irc.demoLine(sidx, line) }

    static func start() {
        Task { @MainActor in
            let ui = UiState.shared, model = AppModel.shared
            // wait until online and in #vitasdk
            for _ in 0..<80 {
                let ready = Irc.locked { !Irc.servers.isEmpty && Irc.servers[0].state == .online && Irc.findChan(Irc.servers[0], "#vitasdk")?.joined == true }
                if ready { break }
                await wait(0.5)
            }
            let s = Irc.locked { Irc.servers[0] }
            let me = Irc.locked { s.nick }
            model.select(0, s.status.uid)
            await wait(2); await step("02_status"); await wait(1)
            ui.showChat = false
            await wait(1.5); await step("03_windows"); await wait(1)

            fake(0, "@time=\(TimeUtil.iso(TimeUtil.now() - 60_000));msgid=d1 :ana!demo@vitairc PRIVMSG \(me) :hola \(me)! mira esto")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://www.youtube.com/watch?v=dQw4w9WgXcQ")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://upload.wikimedia.org/wikipedia/commons/3/3f/Fronalpstock_big.jpg")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://github.com/ArchelKrozt/VitaIRC")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :\u{02}negrita\u{02} y \u{03}04rojo\u{03} normal")
            fake(0, "@msgid=d6;+draft/reply=d1 :ana!demo@vitairc PRIVMSG \(me) :por cierto, ¿viste la versión nueva?")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://upload.wikimedia.org/wikipedia/commons/3/3f/Fronalpstock_big.jpg 🎨 Wikimedia Commons")
            if let q = Irc.locked({ Irc.findChan(s, "ana") }) { model.select(0, q.uid) }
            await wait(9); await step("04_previews"); await wait(1)

            let b = Irc.locked { Irc.getChan(s, "bob", .query) }
            Irc.locked { b.transIn = true; b.transLang = "es" }
            fake(0, ":bob!demo@vitairc PRIVMSG \(me) :Good evening! The weather here is really nice today, how about there?")
            fake(0, ":bob!demo@vitairc PRIVMSG \(me) :I just finished building the new version of the app.")
            model.select(0, b.uid)
            await wait(7); await step("05_translation"); await wait(1)

            if let m = model.chan?.msgs.last { ui.msgSheet = m }
            await wait(2); await step("06_message"); await wait(1)
            ui.msgSheet = nil
            await wait(1)

            if let v = Irc.locked({ Irc.findChan(s, "#vitasdk") }) { model.select(0, v.uid) }
            await wait(2); await step("07_channel"); await wait(2)
            ui.sheet = .users
            await wait(2); await step("08_users"); await wait(1)
            ui.sheet = nil; await wait(1)

            ui.chanListQuery = "vita"
            // the user card: WHOIS and VitaIRC profile (filled locally for the screenshot)
            var prof = Profile(nick: "ana")
            prof.name = "Ana"
            prof.bio = t("Fan de la Vita y del homebrew. Hablo español e inglés; pregúntame por los emuladores 🎮")
            if let logo = UIImage(named: "Logo") { prof.avatar = avatarJpeg(logo, side: 64, maxBytes: 3600) }
            prof.favs = Booru.state.results.prefix(6).map { ProfileFav(engine: $0.engine, id: $0.id, thumb: $0.thumbUrl) }
            if prof.favs.isEmpty {
                Booru.search(Booru.safebooru, "scenery")
                await wait(6)
                prof.favs = Booru.state.results.prefix(6).map { ProfileFav(engine: $0.engine, id: $0.id, thumb: $0.thumbUrl) }
            }
            model.profiles[userKey(0, "ana")] = prof
            var w = WhoisInfo(nick: "ana")
            w.user = "~ana"; w.host = "vitairc/user/ana"; w.realname = "Ana López"; w.server = "tantalum.libera.chat"; w.serverInfo = "Libera"
            w.account = "ana"; w.secure = true; w.idleSecs = 95; w.signon = TimeUtil.now() - 3 * 3600_000; w.channels = ["#vitasdk", "#henkaku", "@#vita-es"]
            model.whoisCards[userKey(0, "ana")] = w
            ui.userCard = UserCardTarget(sidx: 0, nick: "ana")
            await wait(4); await step("08b_user_card"); await wait(1)
            ui.userCard = nil; await wait(1.5)

            ui.sheet = .chanList
            await wait(14); await step("09_channel_search"); await wait(1)
            ui.sheet = nil; await wait(1)

            Booru.search(Booru.safebooru, "scenery cat")
            ui.sheet = .booru
            await wait(9); await step("10_image_search"); await wait(1)
            ui.sheet = nil; await wait(1)
            if let p = Booru.state.results.first { ui.image = ImageTarget(url: p.viewUrl, page: Booru.pageUrl(p), post: p) }
            await wait(6); await step("11_viewer"); await wait(1)
            ui.image = nil; await wait(1)
            ui.miniVideo = VideoTarget(url: "https://www.w3schools.com/html/mov_bbb.mp4", page: "https://www.w3schools.com/html/mov_bbb.mp4")
            await wait(6); await step("12_video"); await wait(1)
            ui.miniVideo = nil; await wait(1)

            ui.sheet = nil; await wait(1.5)
            MyProfile.name = "Diego"
            MyProfile.bio = t("Programo VitaIRC. Me encuentras en #vitasdk.")
            ui.sheet = .myProfile
            await wait(3); await step("12b_my_profile"); await wait(1)
            ui.sheet = nil; await wait(1.5)
            ui.sheet = .settings
            await wait(2); await step("13_settings"); await wait(1)
            ui.sheet = nil; await wait(1.5)
            ui.sheet = .servers
            await wait(2); await step("14_servers"); await wait(1)
            ui.sheet = nil; await wait(1.5)
            ui.sheet = .help
            await wait(2); await step("15_help"); await wait(1)
            ui.sheet = nil
            await step("done")
        }
    }
}
