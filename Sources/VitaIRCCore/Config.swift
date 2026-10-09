import Foundation

/// Settings and servers, stored as config.ini with the same keys as VitaIRC for PS Vita and Android.
public enum Config {
    public static let trpGoogle = 0
    public static let trpOpenAI = 1
    public static let imgLitterbox = 0
    public static let imgImgbb = 1
    public static let imgFilehost = 2
    public static let imgImgur = 3
    public static let updateRepo = "ArchelKrozt/VitaIRC-iOS"

    nonisolated(unsafe) public static var dir = URL(fileURLWithPath: NSTemporaryDirectory())
    nonisolated(unsafe) public static var servers: [ServerCfg] = []

    nonisolated(unsafe) public static var trProvider = trpGoogle
    nonisolated(unsafe) public static var openaiKey = ""
    nonisolated(unsafe) public static var openaiModel = "gpt-4o-mini"
    nonisolated(unsafe) public static var langIn = "es"
    nonisolated(unsafe) public static var langOut = "en"

    nonisolated(unsafe) public static var imgHost = imgLitterbox
    nonisolated(unsafe) public static var imgurId = ""
    nonisolated(unsafe) public static var imgbbKey = ""
    nonisolated(unsafe) public static var imgbbExpire = 0     // 0 never, 1 1h, 2 1 day, 3 1 week, 4 1 month
    nonisolated(unsafe) public static var litterTime = 3      // 0 1h, 1 12h, 2 24h, 3 72h

    nonisolated(unsafe) public static var updateCheck = true
    nonisolated(unsafe) public static var updateLast = ""

    nonisolated(unsafe) public static var linkPreviews = true
    nonisolated(unsafe) public static var searchAdult = false
    nonisolated(unsafe) public static var searchEngine = 0
    nonisolated(unsafe) public static var sankakuUser = ""
    nonisolated(unsafe) public static var sankakuPassword = ""

    nonisolated(unsafe) public static var showJoins = true
    nonisolated(unsafe) public static var notifications = true
    nonisolated(unsafe) public static var fontPct = 100
    nonisolated(unsafe) public static var uiLang = 0          // 0 system, 1 Spanish, 2 English
    nonisolated(unsafe) public static var sound = true
    nonisolated(unsafe) public static var ircColors = true
    nonisolated(unsafe) public static var highlight = ""
    nonisolated(unsafe) public static var ignore = ""

    public static var file: URL { dir.appendingPathComponent("config.ini") }

    public static let langCodes = ["es", "en", "pt", "fr", "de", "it", "ja", "ru", "zh", "ko"]
    public static let langNames = ["Español", "English", "Português", "Français", "Deutsch", "Italiano", "日本語", "Русский", "中文", "한국어"]
    public static func langName(_ code: String) -> String {
        if let i = langCodes.firstIndex(of: code) { return langNames[i] }
        return code
    }

    public static func setup(dir d: URL) {
        dir = d
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        load()
    }

    public static func defaultServer() -> ServerCfg {
        var s = ServerCfg()
        s.nick = "Vita%04d".f(Int.random(in: 0..<10000))
        return s
    }

    private static func bool(_ v: String) -> Bool { v.trimmed == "1" }
    private static func b(_ v: Bool) -> String { v ? "1" : "0" }

    public static func load() {
        servers = []
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            // first start: translate into the phone's language
            let sys = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "es"
            if langCodes.contains(sys) {
                langIn = sys
                langOut = sys == "en" ? "es" : "en"
            }
            servers.append(defaultServer())
            save()
            return
        }
        var cur: Int? = nil
        var hadTranslator = false, hadImageHost = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                if line.hasPrefix("[server]") {
                    var s = ServerCfg(); s.nick = ""; s.channels = ""
                    servers.append(s); cur = servers.count - 1
                } else { cur = nil }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmed
            let v = String(line[line.index(after: eq)...]).trimmed
            if let i = cur {
                switch k {
                case "name": servers[i].name = v
                case "host": servers[i].host = v
                case "port": servers[i].port = Int(v) ?? 6697
                case "ssl": servers[i].ssl = bool(v)
                case "nick": servers[i].nick = v
                case "user": servers[i].user = v
                case "realname": servers[i].realname = v
                case "password": servers[i].password = v
                case "auth": servers[i].auth = Int(v) ?? 0
                case "channels": servers[i].channels = v
                case "autoconnect": servers[i].autoconnect = bool(v)
                default: break
                }
                continue
            }
            switch k {
            case "translator": trProvider = Int(v) ?? 0; hadTranslator = true
            case "openai_key": openaiKey = v
            case "openai_model": openaiModel = v
            case "lang_in": langIn = v
            case "lang_out": langOut = v
            case "image_host": imgHost = Int(v) ?? 0; hadImageHost = true
            case "imgur_client_id": imgurId = v
            case "imgbb_key": imgbbKey = v
            case "imgbb_expire": imgbbExpire = Int(v) ?? 0
            case "litterbox_time": litterTime = Int(v) ?? 3
            case "update_check": updateCheck = bool(v)
            case "update_last": updateLast = v
            case "link_previews": linkPreviews = bool(v)
            case "search_adult": searchAdult = bool(v)
            case "search_engine": searchEngine = Int(v) ?? 0
            case "sankaku_user": sankakuUser = v
            case "sankaku_password": sankakuPassword = v
            case "show_joins": showJoins = bool(v)
            case "notifications": notifications = bool(v)
            case "font_pct": fontPct = Int(v) ?? 100
            case "ui_lang": uiLang = Int(v) ?? 0
            case "sound": sound = bool(v)
            case "irc_colors": ircColors = bool(v)
            case "highlight": highlight = v
            case "ignore": ignore = v
            default: break
            }
        }
        // a config.ini copied from VitaIRC 1.0 keeps ChatGPT / Imgur
        if !hadTranslator { trProvider = openaiKey.isEmpty ? trpGoogle : trpOpenAI }
        if !hadImageHost { imgHost = imgurId.isEmpty ? imgLitterbox : imgImgur }
        trProvider = min(max(trProvider, 0), 1)
        imgHost = min(max(imgHost, 0), 3)
        imgbbExpire = min(max(imgbbExpire, 0), 4)
        litterTime = min(max(litterTime, 0), 3)
        searchEngine = min(max(searchEngine, 0), 2)
        fontPct = min(max(fontPct, 70), 150)
        uiLang = min(max(uiLang, 0), 2)
        for i in servers.indices where servers[i].nick.isEmpty { servers[i].nick = defaultServer().nick }
    }

    private static let saveLock = NSLock()

    public static func save() {
        saveLock.lock(); defer { saveLock.unlock() }
        var sb = "; VitaIRC configuration (same format as VitaIRC for PS Vita).\n[general]\n"
        func kv(_ k: String, _ v: Any) { sb += "\(k)=\(v)\n" }
        kv("translator", trProvider); kv("openai_key", openaiKey); kv("openai_model", openaiModel)
        kv("lang_in", langIn); kv("lang_out", langOut)
        kv("image_host", imgHost); kv("imgur_client_id", imgurId); kv("imgbb_key", imgbbKey)
        kv("imgbb_expire", imgbbExpire); kv("litterbox_time", litterTime)
        kv("update_check", b(updateCheck)); kv("update_last", updateLast)
        kv("link_previews", b(linkPreviews)); kv("search_adult", b(searchAdult)); kv("search_engine", searchEngine)
        kv("sankaku_user", sankakuUser); kv("sankaku_password", sankakuPassword)
        kv("show_joins", b(showJoins)); kv("notifications", b(notifications)); kv("font_pct", fontPct)
        kv("ui_lang", uiLang); kv("sound", b(sound)); kv("irc_colors", b(ircColors))
        kv("highlight", highlight); kv("ignore", ignore)
        for s in servers {
            sb += "\n[server]\n"
            kv("name", s.name); kv("host", s.host); kv("port", s.port); kv("ssl", b(s.ssl))
            kv("nick", s.nick); kv("user", s.user); kv("realname", s.realname); kv("password", s.password)
            kv("auth", s.auth); kv("channels", s.channels); kv("autoconnect", b(s.autoconnect))
        }
        try? sb.write(to: file, atomically: true, encoding: .utf8)
    }
}
