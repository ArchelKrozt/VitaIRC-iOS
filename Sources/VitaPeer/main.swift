// A VitaIRC user without screen, for testing profiles between apps:
//   swift run VitaPeer <nick> [nick to ask] [seconds]
// It connects to Libera.Chat with a profile (photo, bio, a public favorite), answers VPROFILE
// requests and, when given a nick, asks for that user's profile and prints it.
import Foundation
import VitaIRCCore

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let nick = args.count > 1 ? args[1] : "vpeer\(Int.random(in: 100..<999))"
let ask = args.count > 2 ? args[2] : ""
let seconds = args.count > 3 ? Double(args[3]) ?? 180 : 180

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitapeer-\(nick)")
Config.setup(dir: dir)
var cfg = ServerCfg(); cfg.nick = nick; cfg.channels = ""
Config.servers = [cfg]
MyProfile.load()
MyProfile.name = "Peer de prueba"
MyProfile.bio = "Soy un usuario VitaIRC de prueba corriendo en un Mac 🖥️. Mi perfil viaja por IRC."
MyProfile.share = true
if let avatar = ProcessInfo.processInfo.environment["PEER_AVATAR"], let d = FileManager.default.contents(atPath: avatar) {
    try? d.write(to: MyProfile.avatarFile)
}
// one real public favorite
if let r = try? Http.call(Booru.searchUrl(Booru.safebooru, "scenery cat", false, 0, "")), let p = Booru.parse(Booru.safebooru, r.body, false).posts.first {
    Booru.toggleFav(p, thumb: nil)
    MyProfile.setPublic(p.key, true)
    print("public favorite: \(p.key) \(p.thumbUrl)")
}
IrcHooks.profile = { _, n, p in
    if let p = p { print("PROFILE of \(n): name=\(p.name) bio=\(p.bio) avatar=\(p.avatar.count) bytes favs=\(p.favs.map { $0.key }) none=\(p.none)") }
    else { print("PROFILE of \(n): no answer") }
}
Irc.syncFromConfig()
Irc.connect(0)
let s = Irc.servers[0]
let start = Date()
var asked = Date.distantPast
var greeted = false
var lastLines = 0
while Date().timeIntervalSince(start) < seconds {
    Thread.sleep(forTimeInterval: 1)
    let lines = Irc.locked { s.status.msgs.map { $0.text } }
    for l in lines.dropFirst(lastLines) where l.contains("Conectado a") || l.contains("Desconectado") { print("status:", l) }
    lastLines = lines.count
    if !ask.isEmpty && Irc.locked({ s.state == .online }) && Date().timeIntervalSince(asked) > 45 {
        asked = Date()
        if !greeted {
            greeted = true
            Irc.userInput(0, s.status.uid, "/msg \(ask) hola! soy un usuario VitaIRC de prueba: mira mi perfil")
        }
        print("asking \(ask) for the profile...")
        Irc.requestProfile(0, ask)
    }
}
Irc.disconnect(0)
Thread.sleep(forTimeInterval: 2)
