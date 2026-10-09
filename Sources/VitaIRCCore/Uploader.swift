import Foundation

/// Something to upload: a picked photo or a camera shot (already as JPEG/PNG data).
public struct UploadSource { public let name: String; public let mime: String; public let data: Data
    public init(name: String, mime: String, data: Data) { self.name = name; self.mime = mime; self.data = data }
}

/// One entry of uploads.txt
public struct UploadEntry: Identifiable { public let id = UUID(); public let date: String; public let host: String; public let link: String; public let deleteUrl: String }

public enum Uploader {
    public static let hostNames = ["Litterbox", "ImgBB", "soju FILEHOST", "Imgur"]
    public static func hostName(_ h: Int) -> String { h >= 0 && h < hostNames.count ? hostNames[h] : "Litterbox" }
    private static let imgbbSecs = [0, 3600, 86400, 7 * 86400, 30 * 86400]
    private static let litterTimes = ["1h", "12h", "24h", "72h"]
    private static var logFile: URL { Config.dir.appendingPathComponent("uploads.txt") }

    /// nil when uploads can work from this server's windows; otherwise why.
    public static func notReady(_ sidx: Int) -> String? {
        switch Config.imgHost {
        case Config.imgImgur: return Config.imgurId.isEmpty ? t("Configura tu Client-ID de Imgur en Ajustes") : nil
        case Config.imgImgbb: return Config.imgbbKey.isEmpty ? t("Configura tu API key de ImgBB en Ajustes") : nil
        case Config.imgFilehost:
            let fh = Irc.locked { sidx < Irc.servers.count ? Irc.servers[sidx].filehost : "" }
            return fh.isEmpty ? t("Este servidor no ofrece FILEHOST (hace falta soju con file-upload)") : nil
        default: return nil
        }
    }

    /// Uploads in the background; the link (or the error) arrives through AppEvents.upload.
    public static func upload(_ sidx: Int, _ uid: Int64, _ src: UploadSource) {
        appQueue.async {
            let res: UploadResult
            do { res = UploadResult(sidx: sidx, uid: uid, ok: true, text: try uploadNow(sidx, src)) }
            catch { res = UploadResult(sidx: sidx, uid: uid, ok: false, text: (error as? HttpError)?.message ?? error.localizedDescription) }
            AppEvents.busy("")
            AppEvents.upload(res)
        }
    }

    public static func uploadNow(_ sidx: Int, _ src: UploadSource) throws -> String {
        let host = Config.imgHost
        let maxMb = host == Config.imgImgur ? 10 : host == Config.imgImgbb ? 32 : 200
        if src.data.count > maxMb * 1024 * 1024 { throw HttpError(t("%s acepta imágenes de hasta %ld MB").f(hostName(host), maxMb)) }
        AppEvents.busy(t("Subiendo imagen..."))
        let progress: (Int64, Int64) -> Void = { sent, total in
            if total > 0 { AppEvents.busy(t("Subiendo a %s: %d%%").f(hostName(host), Int(sent * 100 / total))) }
        }
        var deleteUrl = ""
        let link: String
        switch host {
        case Config.imgImgur:
            if Config.imgurId.isEmpty { throw HttpError(t("Falta el Client-ID de Imgur (Ajustes)")) }
            let mp = Http.multipart([("type", "file")], file: ("image", src.name, src.mime, src.data))
            let r = try Http.call("https://api.imgur.com/3/image", headers: ["Authorization": "Client-ID \(Config.imgurId)", "Content-Type": mp.contentType],
                                  body: mp.body, timeout: 300, progress: progress)
            let d = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["data"] as? [String: Any]
            if r.ok, let l = d?["link"] as? String, !l.isEmpty { link = l } else {
                let e = d?["error"]
                let msg = (e as? String) ?? ((e as? [String: Any])?["message"] as? String) ?? t("error desconocido")
                throw HttpError("Imgur \(r.code): \(msg.prefix(120))")
            }
        case Config.imgImgbb:
            if Config.imgbbKey.isEmpty { throw HttpError(t("Configura tu API key de ImgBB en Ajustes")) }
            let exp = imgbbSecs[Config.imgbbExpire]
            let url = "https://api.imgbb.com/1/upload?key=" + Http.urlEncode(Config.imgbbKey) + (exp > 0 ? "&expiration=\(exp)" : "")
            let mp = Http.multipart([], file: ("image", src.name, src.mime, src.data))
            let r = try Http.call(url, headers: ["Content-Type": mp.contentType], body: mp.body, timeout: 300, progress: progress)
            let js = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
            let d = js?["data"] as? [String: Any]
            if r.ok, let l = d?["url"] as? String, !l.isEmpty { link = l; deleteUrl = d?["delete_url"] as? String ?? "" } else {
                let msg = ((js?["error"] as? [String: Any])?["message"] as? String) ?? (js?["status_txt"] as? String) ?? t("error desconocido")
                throw HttpError("ImgBB \(r.code): \(msg.prefix(120))")
            }
        case Config.imgFilehost:
            link = try filehost(sidx, src, progress)
        default:
            let mp = Http.multipart([("reqtype", "fileupload"), ("time", litterTimes[Config.litterTime])], file: ("fileToUpload", src.name, src.mime, src.data))
            let r = try Http.call("https://litterbox.catbox.moe/resources/internals/api.php", headers: ["Content-Type": mp.contentType],
                                  body: mp.body, timeout: 300, progress: progress)
            let l = r.text.trimmed
            if r.ok && l.hasPrefix("https://") && !l.contains(" ") { link = l } else {
                throw HttpError("Litterbox \(r.code): \(l.ifEmpty(t("error desconocido")).prefix(120))")
            }
        }
        logUpload(hostName(host), link, deleteUrl)
        return link
    }

    /// soju.im/FILEHOST: raw POST with the IRC account (HTTP Basic), answer 201 + Location.
    private static func filehost(_ sidx: Int, _ src: UploadSource, _ progress: @escaping (Int64, Int64) -> Void) throws -> String {
        let fh: (url: String, user: String, pass: String, host: String, ssl: Bool, certOk: Bool)? = Irc.locked {
            guard sidx < Irc.servers.count else { return nil }
            let s = Irc.servers[sidx]
            return (s.filehost, s.cfg.user.ifEmpty(s.cfg.nick), s.cfg.password, s.cfg.host, s.cfg.ssl, s.certOk)
        }
        guard let f = fh, !f.url.isEmpty else { throw HttpError(t("Este servidor no ofrece FILEHOST (hace falta soju con file-upload)")) }
        if f.ssl && !f.url.hasPrefix("https://") { throw HttpError(t("FILEHOST sin cifrar rechazado: la conexión IRC usa SSL")) }
        if f.pass.isEmpty { throw HttpError(t("FILEHOST necesita tu contraseña del bouncer (Servidores)")) }
        let user = f.user.substringBefore("/").substringBefore("@")     // soju: "user/network@client" -> "user"
        let safe = String(src.name.map { $0 == "\"" || $0 == "\\" || ($0.asciiValue ?? 32) < 32 ? "_" : $0 })
        let urlHost = URL(string: f.url)?.host ?? ""
        let auth = Data("\(user):\(f.pass)".utf8).base64EncodedString()
        let r = try Http.call(f.url, headers: ["Authorization": "Basic \(auth)", "Content-Type": src.mime,
                                               "Content-Disposition": "attachment; filename=\"\(safe)\""],
                              body: src.data, timeout: 300,
                              insecureHost: !f.certOk && urlHost.eqi(f.host) ? urlHost : nil, followRedirects: false, progress: progress)
        if r.code == 401 || r.code == 403 { throw HttpError(t("FILEHOST: usuario o contraseña incorrectos")) }
        if r.code == 413 { throw HttpError(t("FILEHOST: la imagen es demasiado grande para el servidor")) }
        if r.code >= 300 || r.location.isEmpty { throw HttpError("FILEHOST HTTP \(r.code)") }
        return URL(string: r.location, relativeTo: URL(string: f.url))?.absoluteString ?? r.location
    }

    private static func logUpload(_ host: String, _ link: String, _ del: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "\(f.string(from: Date()))\t\(host)\t\(link)\t\(del)\n"
        if let h = try? FileHandle(forWritingTo: logFile) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        else { try? line.write(to: logFile, atomically: true, encoding: .utf8) }
    }

    /// Newest uploads first
    public static func recent(_ max: Int = 30) -> [UploadEntry] {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count >= 3 ? UploadEntry(date: f[0], host: f[1], link: f[2], deleteUrl: f.count > 3 ? f[3] : "") : nil
        }.suffix(max).reversed()
    }
}
