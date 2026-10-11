import Foundation

/// One search result (Safebooru, Danbooru or Sankaku).
public struct BPost: Equatable, Identifiable {
    public let engine: Int
    public let id: String
    public let rating: Character        // g general, s sensitive, q questionable, e explicit
    public let w: Int, h: Int
    public let ext: String
    public let fileSize: Int64
    public var thumbUrl: String
    public var viewUrl: String          // sample shown in the viewer
    public var fileUrl: String          // original
    public var tags: String
    public var artist = ""              // "" when the service doesn't say
    public var key: String { "\(engine)/\(id)" }
}

public struct BooruState {
    public var engine = 0
    public var query = ""
    public var results: [BPost] = []
    public var loading = false
    public var more = false
    public var error = ""
    public init(engine: Int = 0, query: String = "", loading: Bool = false) { self.engine = engine; self.query = query; self.loading = loading }
}

/// JSON values as the Android version reads them (numbers and nulls become text).
func jstr(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
    default: return ""
    }
}
func jint(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int(jstr(v)) ?? 0 }

public enum Booru {
    public static let safebooru = 0, danbooru = 1, sankaku = 2
    public static let maxResults = 240
    public static let maxFavs = 300
    private static let pageSize = 40
    public static let names = ["Safebooru", "Danbooru", "Sankaku"]

    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var _state = BooruState()
    nonisolated(unsafe) private static var _favorites: [BPost] = []
    /// Called (on any thread) when results or favorites change
    nonisolated(unsafe) public static var changed: () -> Void = {}

    public static var state: BooruState { lock.lock(); defer { lock.unlock() }; return _state }
    public static var favorites: [BPost] { lock.lock(); defer { lock.unlock() }; return _favorites }
    private static func setState(_ f: (inout BooruState) -> Void) { lock.lock(); f(&_state); lock.unlock(); changed() }

    nonisolated(unsafe) private static var page = 0
    nonisolated(unsafe) private static var cursor = ""
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var skToken = ""
    nonisolated(unsafe) private static var skTokenUser = ""
    nonisolated(unsafe) private static var skTokenUntil = Date.distantPast

    private static var favFile: URL { Config.dir.appendingPathComponent("favorites.txt") }
    public static var favThumbDir: URL { Config.dir.appendingPathComponent("favthumbs") }

    // MARK: - content filter

    /// Never shown, whatever the settings.
    private static let blockAlways: Set<String> = ["loli", "shota", "lolicon", "shotacon", "toddlercon", "child_abuse", "underage"]
    /// Also hidden on questionable/explicit posts.
    private static let blockMature: Set<String> = ["child", "children", "female_child", "male_child", "kid", "kids", "toddler", "baby",
        "young", "younger", "aged_down", "teenage", "elementary_school_student", "middle_school_student", "school_child"]

    public static func allowed(_ rating: Character, _ tags: String, _ adult: Bool) -> Bool {
        if !adult && rating != "g" { return false }
        let set = Set(tags.split(separator: " ").map(String.init))
        if !set.isDisjoint(with: blockAlways) { return false }
        if (rating == "q" || rating == "e") && !set.isDisjoint(with: blockMature) { return false }
        return true
    }

    private static func ratingCode(_ r: String) -> Character {
        switch r {
        case "general", "safe", "g": return "g"
        case "sensitive", "s": return "s"
        case "questionable", "q", "": return "q"
        default: return "e"
        }
    }

    /// "artist_name" tags -> "artist name, other" ("" when none or only placeholders)
    static func artistName(_ tags: [String]) -> String {
        let skip: Set<String> = ["banned_artist", "unknown_artist", "anonymous_artist", "artist_request", "third-party_edit"]
        return tags.filter { !$0.isEmpty && !skip.contains($0) }.prefix(3).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
    }

    /// The message for the chat: link and, when known, the author ("<url> 🎨 <artist>").
    public static func chatText(_ link: String, _ p: BPost) -> String { p.artist.isEmpty ? link : "\(link) 🎨 \(p.artist)" }

    private static func badExt(_ e: String) -> Bool { e.isEmpty || ["mp4", "webm", "zip", "swf", "avif"].contains(e) }

    static func urlExt(_ url: String) -> String {
        let last = url.substringBefore("?").substringBefore("#").substringAfterLast("/", "")
        return last.contains(".") ? last.substringAfterLast(".").lowercased() : ""
    }

    // MARK: - Sankaku

    public static func imageHeaders(_ engine: Int) -> [String: String] {
        engine == sankaku ? ["Referer": "https://sankaku.app/", "User-Agent": "Mozilla/5.0"] : [:]
    }

    private static func skHeaders() -> [String: String] {
        var h = ["Accept": "application/vnd.sankaku.api+json;v=2", "Origin": "https://sankaku.app"]
        if !skToken.isEmpty { h["Authorization"] = skToken }
        return h
    }

    /// Logs in when an account is set (the token lasts about an hour).
    private static func skLogin() {
        lock.lock(); defer { lock.unlock() }
        let user = Config.sankakuUser, pass = Config.sankakuPassword
        if user.isEmpty || pass.isEmpty { skToken = ""; return }
        if !skToken.isEmpty && Date() < skTokenUntil && user == skTokenUser { return }
        skTokenUser = user
        skToken = ""
        if let body = try? JSONSerialization.data(withJSONObject: ["login": user, "password": pass]),
           let r = try? Http.call("https://sankakuapi.com/auth/token", headers: skHeaders().merging(["Content-Type": "application/json"]) { $1 },
                                  body: body, ua: "Mozilla/5.0"),
           let tok = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["access_token"] as? String, !tok.isEmpty {
            skToken = "Bearer \(tok)"
            skTokenUntil = Date().addingTimeInterval(55 * 60)
        }
        if skToken.isEmpty { AppEvents.toast(t("Sankaku: no se pudo iniciar sesión, se busca sin cuenta")) }
    }

    /// Sankaku links expire after about an hour.
    public static func expired(_ p: BPost) -> Bool {
        guard p.engine == sankaku, let r = p.viewUrl.range(of: "[?&]expires=(\\d+)", options: .regularExpression) else { return false }
        let e = Int64(p.viewUrl[r].split(separator: "=").last ?? "") ?? 0
        return e < Int64(Date().timeIntervalSince1970) + 120
    }

    /// Looks the post up again for fresh links (and keeps them in the lists).
    public static func refresh(_ p: BPost) throws -> BPost {
        skLogin()
        let r = try Http.call("https://sankakuapi.com/v2/posts/keyset?lang=en&limit=1&tags=" + Http.urlEncode("id:\(p.id)"), headers: skHeaders(), ua: "Mozilla/5.0")
        guard r.ok, let f = parse(sankaku, r.body, true).posts.first else {
            throw HttpError(r.ok ? t("Sankaku: la imagen ya no está disponible") : "HTTP \(r.code)")
        }
        var np = p
        np.thumbUrl = f.thumbUrl; np.viewUrl = f.viewUrl; np.fileUrl = f.fileUrl
        lock.lock()
        _state.results = _state.results.map { $0.key == p.key ? np : $0 }
        let isFav = _favorites.contains { $0.key == p.key }
        if isFav { _favorites = _favorites.map { $0.key == p.key ? np : $0 } }
        lock.unlock()
        if isFav { saveFavorites() }
        changed()
        return np
    }

    /// One post by its number (a public favorite of someone else's profile).
    public static func lookup(_ engine: Int, _ id: String) throws -> BPost {
        let safeId = id.filter { $0.isLetter || $0.isNumber }
        let r: HttpResult
        switch engine {
        case safebooru: r = try Http.call("https://safebooru.org/index.php?page=dapi&s=post&q=index&json=1&id=\(safeId)")
        case danbooru: r = try Http.call("https://danbooru.donmai.us/posts/\(safeId).json")
        default:
            skLogin()
            r = try Http.call("https://sankakuapi.com/v2/posts/keyset?lang=en&limit=1&tags=" + Http.urlEncode("id:\(safeId)"), headers: skHeaders(), ua: "Mozilla/5.0")
        }
        if !r.ok { throw HttpError("HTTP \(r.code)") }
        // Danbooru answers one object; the parser reads lists
        let body = engine == danbooru ? Data("[".utf8) + r.body + Data("]".utf8) : r.body
        guard let p = parse(engine, body, Config.searchAdult).posts.first else { throw HttpError(t("Sin resultados.")) }
        return p
    }

    public static func fresh(_ p: BPost) throws -> BPost { expired(p) ? try refresh(p) : p }

    // MARK: - search

    /// Parses one page: kept posts, how many the service sent, next cursor (Sankaku).
    public static func parse(_ engine: Int, _ json: Data, _ adult: Bool) -> (posts: [BPost], raw: Int, next: String) {
        var out: [BPost] = []
        var raw = 0
        var next = ""
        let any = try? JSONSerialization.jsonObject(with: json)
        let arr: [[String: Any]]
        if engine == sankaku {
            let o = any as? [String: Any]
            next = jstr((o?["meta"] as? [String: Any])?["next"])
            arr = (o?["data"] as? [[String: Any]]) ?? []
        } else {
            arr = (any as? [[String: Any]]) ?? []
        }
        for it in arr {
            raw += 1
            var p: BPost
            let tags: String
            switch engine {
            case safebooru:
                let file = jstr(it["file_url"])
                tags = jstr(it["tags"]).trimmed
                let sample = jstr(it["sample"]).eqi("true") || jstr(it["sample"]) == "1"
                p = BPost(engine: engine, id: jstr(it["id"]), rating: ratingCode(jstr(it["rating"])), w: jint(it["width"]), h: jint(it["height"]),
                          ext: urlExt(file), fileSize: 0, thumbUrl: jstr(it["preview_url"]), viewUrl: sample ? jstr(it["sample_url"]) : file, fileUrl: file, tags: tags)
            case danbooru:
                tags = jstr(it["tag_string"])
                p = BPost(engine: engine, id: jstr(it["id"]), rating: ratingCode(jstr(it["rating"])), w: jint(it["image_width"]), h: jint(it["image_height"]),
                          ext: jstr(it["file_ext"]).lowercased(), fileSize: Int64(jint(it["file_size"])), thumbUrl: jstr(it["preview_file_url"]),
                          viewUrl: jstr(it["large_file_url"]), fileUrl: jstr(it["file_url"]), tags: tags)
                p.artist = artistName(jstr(it["tag_string_artist"]).split(separator: " ").map(String.init))
            default:
                if jstr(it["is_premium"]) == "true" || jstr(it["redirect_to_signup"]) == "true" { continue }
                let ta = (it["tags"] as? [[String: Any]]) ?? []
                tags = ta.compactMap { o -> String? in
                    let n = jstr(o["tagName"]).ifEmpty(jstr(o["name_en"]).ifEmpty(jstr(o["name"])))
                    return n.isEmpty ? nil : n.replacingOccurrences(of: " ", with: "_")
                }.joined(separator: " ")
                let artists = ta.compactMap { o -> String? in
                    jint(o["type"]) == 1 ? jstr(o["tagName"]).ifEmpty(jstr(o["name_en"]).ifEmpty(jstr(o["name"]))) : nil
                }
                let sample = jstr(it["sample_url"])
                let r = jstr(it["rating"])
                p = BPost(engine: engine, id: jstr(it["id"]), rating: r == "s" ? "g" : ratingCode(r), w: jint(it["width"]), h: jint(it["height"]),
                          ext: jstr(it["file_ext"]).lowercased(), fileSize: Int64(jint(it["file_size"])), thumbUrl: sample, viewUrl: sample,
                          fileUrl: jstr(it["file_url"]), tags: tags)
                p.artist = artistName(artists)
            }
            if p.viewUrl.isEmpty { p.viewUrl = p.fileUrl }
            if !p.id.isEmpty && !p.fileUrl.isEmpty && !p.thumbUrl.isEmpty && !badExt(p.ext) && allowed(p.rating, tags, adult) {
                p.tags = String(tags.prefix(300))
                out.append(p)
            }
        }
        return (out, raw, next)
    }

    public static func searchUrl(_ engine: Int, _ query: String, _ adult: Bool, _ page: Int, _ cursor: String) -> String {
        let safe = engine == safebooru ? " rating:general" : engine == danbooru ? " rating:g" : " rating:safe"
        let q = Http.urlEncode((query + (adult ? "" : safe)).trimmed)
        switch engine {
        case safebooru: return "https://safebooru.org/index.php?page=dapi&s=post&q=index&json=1&limit=\(pageSize)&pid=\(page)&tags=\(q)"
        case danbooru: return "https://danbooru.donmai.us/posts.json?limit=\(pageSize)&page=\(page + 1)&tags=\(q)"
        default: return "https://sankakuapi.com/v2/posts/keyset?lang=en&limit=\(pageSize)&tags=\(q)" + (cursor.isEmpty ? "" : "&next=\(cursor)")
        }
    }

    public static func search(_ engine: Int, _ query: String) {
        lock.lock()
        generation += 1
        page = 0
        cursor = ""
        _state = BooruState(engine: engine, query: query.trimmed, loading: true)
        lock.unlock()
        changed()
        fetchPage()
    }

    public static func more() {
        lock.lock()
        let s = _state
        if !s.more || s.loading { lock.unlock(); return }
        _state.loading = true
        lock.unlock()
        changed()
        fetchPage()
    }

    public static func setEngine(_ e: Int) { setState { $0.engine = e } }

    private static func fetchPage() {
        let gen = generation
        appQueue.async {
            var s = state
            do {
                // a page can come back empty after filtering: keep paging a little
                for _ in 0..<4 {
                    if s.engine == sankaku { skLogin() }
                    let r = try Http.call(searchUrl(s.engine, s.query, Config.searchAdult, page, cursor),
                                          headers: s.engine == sankaku ? skHeaders() : [:], ua: s.engine == sankaku ? "Mozilla/5.0" : nil)
                    if gen != generation { return }
                    if !r.ok {
                        let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
                        let msg = jstr(o?["message"]).ifEmpty(jstr(o?["error"]))
                        throw HttpError(msg.isEmpty ? "HTTP \(r.code)" : "\(names[s.engine]): \(msg.prefix(120))")
                    }
                    let res = parse(s.engine, r.body, Config.searchAdult)
                    page += 1
                    cursor = res.next
                    let have = Set(s.results.map { $0.key })
                    let all = Array((s.results + res.posts.filter { !have.contains($0.key) }).prefix(maxResults))
                    let more = res.raw > 0 && all.count < maxResults && (s.engine == sankaku ? !res.next.isEmpty : res.raw >= pageSize)
                    s.results = all; s.more = more; s.error = ""
                    if !res.posts.isEmpty || !more { break }
                }
                s.loading = false
            } catch {
                s.loading = false; s.more = false; s.error = (error as? HttpError)?.message ?? error.localizedDescription
            }
            lock.lock()
            if gen == generation { _state = s }
            lock.unlock()
            changed()
        }
    }

    // MARK: - favorites

    public static func isFav(_ p: BPost) -> Bool { favorites.contains { $0.key == p.key } }

    public static func thumbFile(_ p: BPost) -> URL {
        favThumbDir.appendingPathComponent("\(p.engine)_\(String(p.id.map { $0.isLetter || $0.isNumber ? $0 : "_" })).jpg")
    }

    /// Adds or removes a favorite; `thumb` is a small JPEG kept on the device. Returns true when added.
    @discardableResult
    public static func toggleFav(_ p: BPost, thumb: Data?) -> Bool {
        lock.lock()
        if _favorites.contains(where: { $0.key == p.key }) {
            _favorites.removeAll { $0.key == p.key }
            lock.unlock()
            try? FileManager.default.removeItem(at: thumbFile(p))
            saveFavorites(); changed()
            return false
        }
        if _favorites.count >= maxFavs {
            lock.unlock()
            AppEvents.toast(t("Tienes demasiados favoritos (máximo %d)").f(maxFavs))
            return false
        }
        _favorites.insert(p, at: 0)          // newest first
        lock.unlock()
        if let th = thumb {
            try? FileManager.default.createDirectory(at: favThumbDir, withIntermediateDirectories: true)
            try? th.write(to: thumbFile(p))
        }
        saveFavorites(); changed()
        return true
    }

    /// engine, id, rating, w, h, ext, size, thumb, view, file, tags (same as VitaIRC for PS Vita)
    private static func saveFavorites() {
        let f = favorites
        if f.isEmpty { try? FileManager.default.removeItem(at: favFile); return }
        let text = f.map { p in
            "\(p.engine)\t\(p.id)\t\(p.rating)\t\(p.w)\t\(p.h)\t\(p.ext)\t\(p.fileSize)\t\(p.thumbUrl)\t\(p.viewUrl)\t\(p.fileUrl)\t\(p.tags.replacingOccurrences(of: "\t", with: " "))\t\(p.artist.replacingOccurrences(of: "\t", with: " "))\n"
        }.joined()
        try? text.write(to: favFile, atomically: true, encoding: .utf8)
    }

    public static func loadFavorites() {
        var list: [BPost] = []
        if let text = try? String(contentsOf: favFile, encoding: .utf8) {
            for l in text.split(separator: "\n") {
                let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 10, let e = Int(f[0]), (0...2).contains(e) else { continue }
                var p = BPost(engine: e, id: f[1], rating: f[2].first ?? "g", w: Int(f[3]) ?? 0, h: Int(f[4]) ?? 0, ext: f[5],
                              fileSize: Int64(f[6]) ?? 0, thumbUrl: f[7], viewUrl: f[8], fileUrl: f[9], tags: f.count > 10 ? f[10] : "")
                p.artist = f.count > 11 ? f[11] : ""
                list.append(p)
            }
        }
        lock.lock()
        _favorites = Array(list.prefix(maxFavs))
        _state.engine = Config.searchEngine
        lock.unlock()
        changed()
    }

    public static func pageUrl(_ p: BPost) -> String {
        switch p.engine {
        case danbooru: return "https://danbooru.donmai.us/posts/\(p.id)"
        case sankaku: return "https://sankaku.app/posts/\(p.id)"
        default: return "https://safebooru.org/index.php?page=post&s=view&id=\(p.id)"
        }
    }

    /// Downloads an image of a post (Sankaku needs a Referer).
    public static func download(_ p: BPost, _ url: String, max: Int = 40 * 1024 * 1024) throws -> HttpResult {
        let r = try Http.call(url, headers: imageHeaders(p.engine), max: max, ua: p.engine == sankaku ? "Mozilla/5.0" : nil)
        if !r.ok { throw HttpError("HTTP \(r.code)") }
        return r
    }

    /// Link for the chat: Safebooru/Danbooru links are permanent and go directly; Sankaku's expire
    /// within the hour, so the image is re-uploaded with the image service. Arrives via AppEvents.upload.
    public static func send(_ p0: BPost, _ sidx: Int, _ uid: Int64) {
        appQueue.async {
            let res: UploadResult
            do {
                if p0.engine != sankaku { res = UploadResult(sidx: sidx, uid: uid, ok: true, text: chatText(p0.fileUrl, p0)) } else {
                    let p = try fresh(p0)
                    let original = (1...8 * 1024 * 1024).contains(p.fileSize)
                    let url = original ? p.fileUrl : p.viewUrl
                    AppEvents.busy(t("Descargando imagen..."))
                    let data = try download(p, url).body
                    let ext = urlExt(url).ifEmpty("jpg")
                    let mime = ext == "png" ? "image/png" : ext == "webp" ? "image/webp" : ext == "gif" ? "image/gif" : "image/jpeg"
                    let link = try Uploader.uploadNow(sidx, UploadSource(name: "sankaku_\(p.id).\(ext)", mime: mime, data: data))
                    res = UploadResult(sidx: sidx, uid: uid, ok: true, text: chatText(link, p))
                }
            } catch {
                res = UploadResult(sidx: sidx, uid: uid, ok: false, text: (error as? HttpError)?.message ?? error.localizedDescription)
            }
            AppEvents.busy("")
            AppEvents.upload(res)
        }
    }
}
