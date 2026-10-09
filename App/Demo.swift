import SwiftUI
import VitaIRCCore

/// VITAIRC_DEMO=1: walks through the screens by itself so the build can take screenshots
/// (tools/screenshots.sh reads the step from Documents/demo_step.txt). The messages it adds
/// are local only: nothing is sent to the network.
@MainActor
enum Demo {
    static func step(_ name: String) {
        let f = Config.dir.appendingPathComponent("demo_step.txt")
        try? name.write(to: f, atomically: true, encoding: .utf8)
    }

    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// A message from someone else, as if it came from the server (only in this window, never sent).
    static func fake(_ sidx: Int, _ line: String) { Irc.demoLine(sidx, line) }

    static func start() {
        Task { @MainActor in
            let ui = UiState.shared, model = AppModel.shared
            step("01_start"); await wait(4)
            // wait until online and in #vitasdk
            for _ in 0..<80 {
                let ready = Irc.locked { !Irc.servers.isEmpty && Irc.servers[0].state == .online && Irc.findChan(Irc.servers[0], "#vitasdk")?.joined == true }
                if ready { break }
                await wait(0.5)
            }
            let s = Irc.locked { Irc.servers[0] }
            let me = Irc.locked { s.nick }
            model.select(0, s.status.uid)
            await wait(2); step("02_status"); await wait(3)
            ui.showChat = false
            await wait(1.5); step("03_windows"); await wait(3)

            fake(0, "@time=\(TimeUtil.iso(TimeUtil.now() - 60_000)) :ana!demo@vitairc PRIVMSG \(me) :hola \(me)! mira esto")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://www.youtube.com/watch?v=dQw4w9WgXcQ")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://upload.wikimedia.org/wikipedia/commons/3/3f/Fronalpstock_big.jpg")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :https://github.com/ArchelKrozt/VitaIRC")
            fake(0, ":ana!demo@vitairc PRIVMSG \(me) :\u{02}negrita\u{02} y \u{03}04rojo\u{03} normal")
            if let q = Irc.locked({ Irc.findChan(s, "ana") }) { model.select(0, q.uid) }
            await wait(9); step("04_previews"); await wait(3)

            let b = Irc.locked { Irc.getChan(s, "bob", .query) }
            Irc.locked { b.transIn = true }
            fake(0, ":bob!demo@vitairc PRIVMSG \(me) :Good evening! The weather here is really nice today, how about there?")
            fake(0, ":bob!demo@vitairc PRIVMSG \(me) :I just finished building the new version of the app.")
            model.select(0, b.uid)
            await wait(7); step("05_translation"); await wait(3)

            if let m = model.chan?.msgs.last { ui.msgSheet = m }
            await wait(2); step("06_message"); await wait(3)
            ui.msgSheet = nil
            await wait(1)

            if let v = Irc.locked({ Irc.findChan(s, "#vitasdk") }) { model.select(0, v.uid) }
            await wait(2); step("07_channel"); await wait(2)
            ui.sheet = .users
            await wait(2); step("08_users"); await wait(3)
            ui.sheet = nil; await wait(1)

            ui.chanListQuery = "vita"
            ui.sheet = .chanList
            await wait(14); step("09_channel_search"); await wait(3)
            ui.sheet = nil; await wait(1)

            Booru.search(Booru.safebooru, "scenery cat")
            ui.sheet = .booru
            await wait(9); step("10_image_search"); await wait(3)
            ui.sheet = nil; await wait(1)
            if let p = Booru.state.results.first { ui.image = ImageTarget(url: p.viewUrl, page: Booru.pageUrl(p), post: p) }
            await wait(6); step("11_viewer"); await wait(3)
            ui.image = nil; await wait(1)
            ui.video = VideoTarget(url: "https://www.w3schools.com/html/mov_bbb.mp4", page: "https://www.w3schools.com/html/mov_bbb.mp4")
            await wait(6); step("12_video"); await wait(3)
            ui.video = nil; await wait(1)

            ui.sheet = .settings
            await wait(2); step("13_settings"); await wait(3)
            ui.sheet = .servers
            await wait(2); step("14_servers"); await wait(3)
            ui.sheet = .help
            await wait(2); step("15_help"); await wait(3)
            ui.sheet = nil
            step("done")
        }
    }
}
