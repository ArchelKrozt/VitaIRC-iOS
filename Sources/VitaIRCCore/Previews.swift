import Foundation

public enum LinkKind { case image, video, page }

/// What a link in the chat shows under its message.
public struct LinkPreview: Equatable {
    public let url: String
    public let kind: LinkKind
    public let ok: Bool
    public var title = ""
    public var desc = ""
    public var site = ""
    public var image = ""          // picture for the thumbnail (page's og:image, video poster...)
    public var media = ""          // direct image or video URL
    public var size: Int64 = -1
    public var videoSite = false   // page of a video (YouTube...)
    public var gif = false
}

public enum Previews {
    private static let maxCache = 200
    private static let pageMax = 768 * 1024
    private static var ua: String { "Mozilla/5.0 (compatible; \(Http.userAgent); link preview)" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: LinkPreview] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated(unsafe) private static var waiting: [String: [(LinkPreview) -> Void]] = [:]

    // MARK: - URL helpers

    static func ext(_ url: String) -> String { Booru.urlExt(url) }

    public static func host(_ url: String) -> String {
        let h = URL(string: url)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// imgur.com/<id> -> its picture (albums and galleries stay pages)
    private static func imgurId(_ url: String) -> String? {
        let h = host(url)
        guard h == "imgur.com" || h == "m.imgur.com", let r = url.range(of: "imgur.com/") else { return nil }
        let p = String(url[r.upperBound...])
        if p.isEmpty || ["a/", "gallery/", "t/", "user/"].contains(where: { p.hasPrefix($0) }) { return nil }
        let id = String(p.prefix { !"/?#.".contains($0) })
        return id.isEmpty ? nil : id
    }

    /// Direct picture for a link the viewer can open.
    public static func imageUrl(_ url: String) -> String? {
        if ["png", "jpg", "jpeg", "webp", "gif"].contains(ext(url)) { return url }
        return imgurId(url).map { "https://i.imgur.com/\($0).jpg" }
    }

    public static func kindOf(_ url: String) -> LinkKind {
        let e = ext(url)
        if ["png", "jpg", "jpeg", "webp", "gif"].contains(e) || imgurId(url) != nil { return .image }
        if ["mp4", "m4v", "mov", "webm", "gifv", "mkv"].contains(e) { return .video }
        return .page
    }

    /// Animated "GIF" that is really a short video (Imgur's .gifv): plays inline, muted, looping
    public static func isLoop(_ url: String) -> Bool { ext(url) == "gifv" }

    /// Imgur's .gifv is an MP4
    public static func videoUrl(_ url: String) -> String { ext(url) == "gifv" ? url.substringBeforeLast(".") + ".mp4" : url }

    private static func isYoutube(_ url: String) -> Bool { ["youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com"].contains(host(url)) }

    // MARK: - cache

    public static func cached(_ url: String) -> LinkPreview? { lock.lock(); defer { lock.unlock() }; return cache[url] }

    /// Cached preview, or fetched once in the background (several messages with one link share the request).
    public static func load(_ url: String, _ done: @escaping (LinkPreview) -> Void) {
        lock.lock()
        if let c = cache[url] { lock.unlock(); done(c); return }
        if waiting[url] != nil { waiting[url]!.append(done); lock.unlock(); return }
        waiting[url] = [done]
        lock.unlock()
        appQueue.async {
            let r = (try? fetch(url)) ?? LinkPreview(url: url, kind: kindOf(url), ok: false)
            lock.lock()
            if cache[url] == nil { order.append(url) }
            cache[url] = r
            while order.count > maxCache { cache.removeValue(forKey: order.removeFirst()) }
            let cbs = waiting.removeValue(forKey: url) ?? []
            lock.unlock()
            for cb in cbs { cb(r) }
        }
    }

    // MARK: - fetching

    public static func fetch(_ url: String) throws -> LinkPreview {
        switch kindOf(url) {
        case .image:
            let direct = imageUrl(url) ?? url
            return LinkPreview(url: url, kind: .image, ok: true, site: host(url), image: direct, media: direct, gif: ext(direct) == "gif")
        case .video: return video(url, videoUrl(url))
        case .page: return try page(url)
        }
    }

    private static func video(_ url: String, _ media: String) -> LinkPreview {
        var size: Int64 = -1
        if let h = try? Http.call(media, method: "HEAD", ua: ua), h.ok { size = h.length }
        // Imgur keeps a still picture of each video
        let poster = host(media) == "i.imgur.com" ? media.substringBeforeLast(".") + ".jpg" : ""
        return LinkPreview(url: url, kind: .video, ok: true, title: media.substringBefore("?").substringAfterLast("/"), site: host(url),
                           image: poster, media: media, size: size)
    }

    private static func youtube(_ url: String) throws -> LinkPreview {
        let r = try Http.call("https://www.youtube.com/oembed?format=json&url=" + Http.urlEncode(url), max: 64 * 1024)
        guard r.ok, let js = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { return LinkPreview(url: url, kind: .page, ok: false) }
        let title = jstr(js["title"])
        return LinkPreview(url: url, kind: .page, ok: !title.isEmpty, title: title, desc: jstr(js["author_name"]), site: "YouTube",
                           image: jstr(js["thumbnail_url"]), videoSite: true)
    }

    private static func page(_ url: String) throws -> LinkPreview {
        if isYoutube(url) { return try youtube(url) }
        // a link without extension may still be a picture or a video
        if let h = try? Http.call(url, method: "HEAD", ua: ua), h.ok {
            if h.contentType.hasPrefix("image/") {
                return LinkPreview(url: url, kind: .image, ok: true, site: host(url), image: h.finalUrl, media: h.finalUrl, gif: h.contentType == "image/gif")
            }
            if h.contentType.hasPrefix("video/") { return video(url, h.finalUrl) }
        }
        let r = try Http.call(url, max: pageMax, ua: ua)
        // servers that refuse HEAD: the answer itself says what the link is
        if r.ok && r.contentType.hasPrefix("image/") {
            return LinkPreview(url: url, kind: .image, ok: true, site: host(url), image: r.finalUrl, media: r.finalUrl, gif: r.contentType == "image/gif")
        }
        if r.ok && r.contentType.hasPrefix("video/") { return video(url, r.finalUrl) }
        if !r.ok || (!r.contentType.isEmpty && r.contentType != "text/html" && r.contentType != "application/xhtml+xml") {
            return LinkPreview(url: url, kind: .page, ok: false)
        }
        let meta = Html.meta(r.text)
        let img = meta.image.isEmpty ? "" : resolve(r.finalUrl, meta.image)
        return LinkPreview(url: url, kind: .page, ok: !meta.title.isEmpty || !img.isEmpty, title: meta.title, desc: meta.desc,
                           site: meta.site.ifEmpty(host(r.finalUrl)), image: img, videoSite: meta.video)
    }

    /// Resolves a link found in a page against the page's address.
    public static func resolve(_ base: String, _ ref: String) -> String {
        URL(string: ref.trimmed, relativeTo: URL(string: base))?.absoluteString ?? ref
    }
}

/// og:/twitter: tags and <title> of a page.
public enum Html {
    public struct Meta { public let title, desc, site, image: String; public let video: Bool }

    private static func attr(_ tag: String, _ name: String) -> String? {
        let pat = "\\s\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for g in 2...4 { if let r = Range(m.range(at: g), in: tag) { return String(tag[r]) } }
        return ""
    }

    public static func meta(_ html: String) -> Meta {
        let head = html.range(of: "</head", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        var m: [String: String] = [:]
        if let re = try? NSRegularExpression(pattern: "<meta\\s[^>]*>", options: .caseInsensitive) {
            for match in re.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
                guard let r = Range(match.range, in: head) else { continue }
                let tag = String(head[r])
                guard let key = (attr(tag, "property") ?? attr(tag, "name"))?.lowercased(), let v = attr(tag, "content") else { continue }
                if m[key] == nil { m[key] = v }
            }
        }
        var titleTag: String?
        if let re = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let mt = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)), let r = Range(mt.range(at: 1), in: head) {
            titleTag = String(head[r])
        }
        return Meta(title: text(m["og:title"] ?? m["twitter:title"] ?? titleTag ?? ""),
                    desc: text(m["og:description"] ?? m["twitter:description"] ?? m["description"] ?? ""),
                    site: text(m["og:site_name"] ?? ""),
                    image: text(m["og:image"] ?? m["og:image:secure_url"] ?? m["og:image:url"] ?? m["twitter:image"] ?? m["twitter:image:src"] ?? ""),
                    video: (m["og:type"] ?? "").hasPrefix("video"))
    }

    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                   "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»"]

    /// Entities decoded, whitespace collapsed.
    public static func text(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#\\d+|[a-zA-Z]+);") else { return s }
        var out = ""
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s), let g = Range(m.range(at: 1), in: s) else { continue }
            out += s[last..<r.lowerBound]
            let e = String(s[g])
            var rep: String?
            if e.hasPrefix("#x") || e.hasPrefix("#X") { rep = UInt32(e.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String(Character($0)) } }
            else if e.hasPrefix("#") { rep = UInt32(e.dropFirst()).flatMap(UnicodeScalar.init).map { String(Character($0)) } }
            else { rep = entities[e] }
            if rep == "\u{0}" { rep = nil }
            out += rep ?? String(s[r])
            last = r.upperBound
        }
        out += s[last...]
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
