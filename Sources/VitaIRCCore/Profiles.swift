import Foundation

/// Someone's VitaIRC profile, received over IRC (see PROFILE-PROTOCOL.md).
public struct Profile: Equatable {
    public var nick: String
    public var name = ""
    public var bio = ""
    public var avatar = Data()           // JPEG
    public var favs: [ProfileFav] = []
    public var none = false              // the owner doesn't share a profile
    public init(nick: String) { self.nick = nick }
}

public struct ProfileFav: Equatable, Identifiable, Hashable {
    public let engine: Int
    public let id: String
    public let thumb: String             // "" when not sent (Sankaku)
    public var key: String { "\(engine)/\(id)" }
    public init(engine: Int, id: String, thumb: String) { self.engine = engine; self.id = id; self.thumb = thumb }
}

/// WHOIS answer gathered into one card.
public struct WhoisInfo: Equatable {
    public var nick: String
    public var user = "", host = "", realname = "", server = "", serverInfo = "", account = "", away = ""
    public var channels: [String] = []
    public var idleSecs = -1
    public var signon: Int64 = 0
    public var secure = false
    public var oper = false
    public var actualHost = ""
    public var found = true
    public init(nick: String, found: Bool = true) { self.nick = nick; self.found = found }
}

/// My own profile: name, bio, avatar and which favorites are public. Stored on the device only.
public enum MyProfile {
    public static let maxName = 40
    public static let maxBio = 280
    public static let maxFavs = 12

    nonisolated(unsafe) public static var name = ""
    nonisolated(unsafe) public static var bio = ""
    nonisolated(unsafe) public static var share = true
    nonisolated(unsafe) public static var publicFavs: [String] = []      // "<engine>/<id>"

    static var file: URL { Config.dir.appendingPathComponent("profile.txt") }
    public static var avatarFile: URL { Config.dir.appendingPathComponent("profile_avatar.jpg") }
    public static var avatarBigFile: URL { Config.dir.appendingPathComponent("profile_avatar_big.jpg") }
    static var favsFile: URL { Config.dir.appendingPathComponent("profile_favs.txt") }

    public static func load() {
        name = ""; bio = ""; share = true; publicFavs = []
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for l in text.split(separator: "\n") {
                let k = String(l).substringBefore("="), v = String(l).substringAfter("=")
                switch k {
                case "name": name = v
                case "bio": bio = v.replacingOccurrences(of: "\\n", with: "\n")
                case "share": share = v != "0"
                default: break
                }
            }
        }
        if let text = try? String(contentsOf: favsFile, encoding: .utf8) {
            publicFavs = text.split(separator: "\n").map(String.init).filter { $0.contains("/") }
        }
    }

    public static func save() {
        let text = "name=\(name.replacingOccurrences(of: "\n", with: " "))\nbio=\(bio.replacingOccurrences(of: "\n", with: "\\n"))\nshare=\(share ? 1 : 0)\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
        try? (publicFavs.joined(separator: "\n") + "\n").write(to: favsFile, atomically: true, encoding: .utf8)
    }

    public static func isPublic(_ key: String) -> Bool { publicFavs.contains(key) }

    /// Marks a favorite public or private. Returns false when the limit was reached.
    @discardableResult
    public static func setPublic(_ key: String, _ on: Bool) -> Bool {
        if on {
            if publicFavs.contains(key) { return true }
            if publicFavs.count >= maxFavs { return false }
            publicFavs.append(key)
        } else { publicFavs.removeAll { $0 == key } }
        save()
        return true
    }

    public static var avatar: Data { (try? Data(contentsOf: avatarFile)) ?? Data() }

    /// The answer lines (without the CTCP wrapping).
    static func answerLines() -> [String] {
        if !share { return ["NONE"] }
        var out = ["BEGIN 1"]
        if !name.isEmpty { out.append("NAME " + String(name.prefix(maxName))) }
        for chunk in chunks(String(bio.prefix(maxBio)).replacingOccurrences(of: "\n", with: " "), maxBytes: 200) { out.append("BIO " + chunk) }
        let b64 = avatar.base64EncodedString()
        var i = b64.startIndex
        while i < b64.endIndex {
            let e = b64.index(i, offsetBy: 300, limitedBy: b64.endIndex) ?? b64.endIndex
            out.append("AVATAR " + b64[i..<e])
            i = e
        }
        let favs = Booru.favorites
        for key in publicFavs.prefix(maxFavs) {
            guard let p = favs.first(where: { $0.key == key }) else { continue }
            let thumb = p.engine == Booru.sankaku || p.thumbUrl.isEmpty || p.thumbUrl.utf8.count > 250 ? "-" : p.thumbUrl
            out.append("FAV \(p.engine) \(p.id) \(thumb)")
        }
        out.append("END")
        return out
    }

    /// Text cut at character boundaries into pieces of at most maxBytes UTF-8 bytes.
    static func chunks(_ s: String, maxBytes: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            if cur.utf8.count + String(ch).utf8.count > maxBytes { out.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// A profile being received
final class ProfileBuild {
    var p: Profile
    var started: Bool = false
    var avatarB64 = ""
    let askedAt: Int64
    var lastAt: Int64
    init(_ nick: String) { p = Profile(nick: nick); askedAt = TimeUtil.now(); lastAt = askedAt }
}
