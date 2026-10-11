import Foundation

/// Translation with Google's free endpoint or ChatGPT, cached on disk like VitaIRC for PS Vita.
public enum Translator {
    private static let cacheMax = 256

    /// OpenAI usage: today, total, requests
    nonisolated(unsafe) public private(set) static var usage: (today: Int, total: Int, requests: Int) = (0, 0, 0)
    nonisolated(unsafe) private static var usageDate = ""

    private struct Job { let outgoing: Bool; let sidx: Int; let uid: Int64; let mid: Int64; let text: String; let lang: String; var replyTo: String? = nil }

    private static let lock = NSCondition()
    nonisolated(unsafe) private static var jobs: [Job] = []
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []

    private static var cacheFile: URL { Config.dir.appendingPathComponent("trcache.txt") }
    private static var usageFile: URL { Config.dir.appendingPathComponent("usage.txt") }

    public static func ready() -> Bool { Config.trProvider != Config.trpOpenAI || !Config.openaiKey.isEmpty }
    public static func providerName(_ p: Int) -> String { p == Config.trpOpenAI ? "ChatGPT (OpenAI)" : t("Google (gratis)") }

    public static func start() {
        loadCache()
        loadUsage()
        let th = Thread {
            while true {
                lock.lock()
                while jobs.isEmpty { lock.wait() }
                let j = jobs.removeFirst()
                lock.unlock()
                run(j)
            }
        }
        th.name = "translator"
        th.start()
    }

    /// Incoming message: the result goes under it.
    public static func requestIn(_ s: Server, _ c: Chan, _ m: Msg, onDemand: Bool = false) {
        let j = Job(outgoing: false, sidx: s.idx, uid: c.uid, mid: m.id, text: m.text, lang: Irc.chanLang(c))
        lock.lock()
        if onDemand { jobs.insert(j, at: 0) } else {
            // background translations: drop the oldest when too many are waiting
            if jobs.count > 64 { jobs.removeLast() }
            jobs.append(j)
        }
        lock.signal(); lock.unlock()
    }

    /// My message: sent translated once ready (or as it was, on error).
    public static func requestOut(_ s: Server, _ c: Chan, _ text: String) {
        lock.lock()
        jobs.insert(Job(outgoing: true, sidx: s.idx, uid: c.uid, mid: 0, text: text, lang: Config.langOut, replyTo: Irc.takeReplyOut(c)), at: 0)
        lock.signal(); lock.unlock()
    }

    private static func cached(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return cache[key] }

    private static func run(_ j: Job) {
        let key = j.lang + "\t" + j.text
        if !j.outgoing, let c = cached(key) { finishIn(j, c); return }
        AppEvents.busy(j.outgoing ? t("Traduciendo mensaje...") : t("Traduciendo..."))
        defer { AppEvents.busy("") }
        do {
            let r = try translate(j.text, j.lang, j.outgoing)
            if j.outgoing { Irc.sendPrivmsg(j.sidx, j.uid, r.ifEmpty(j.text), replyTo: j.replyTo) } else { putCache(key, r); finishIn(j, r) }
        } catch {
            let msg = (error as? HttpError)?.message ?? error.localizedDescription
            if j.outgoing {
                AppEvents.toast(t("No se pudo traducir (%s). Enviado sin traducir.").f(msg.ifEmpty(t("vacío"))))
                Irc.sendPrivmsg(j.sidx, j.uid, j.text, replyTo: j.replyTo)
            } else {
                finishIn(j, nil)
                AppEvents.toast(t("Traducción: %s").f(msg))
            }
        }
    }

    private static func finishIn(_ j: Job, _ res: String?) {
        Irc.locked {
            guard j.sidx < Irc.servers.count, let m = Irc.findChanUid(Irc.servers[j.sidx], j.uid)?.findMsg(j.mid) else { return }
            // show only when it actually differs from the original
            if let r = res, !r.isEmpty, r != m.text { m.trans = r; m.transState = .done } else { m.transState = .skip }
            Irc.dirty()
        }
    }

    public static func translate(_ text: String, _ lang: String, _ outgoing: Bool) throws -> String {
        Config.trProvider == Config.trpOpenAI ? try openai(text, lang, outgoing) : try google(text, lang, outgoing)
    }

    /// Google Translate's free web endpoint: no key, detects the source language.
    private static func google(_ text: String, _ lang: String, _ outgoing: Bool) throws -> String {
        let tl = lang == "zh" ? "zh-CN" : lang
        let r = try Http.call("https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(tl)&dt=t&q=" + Http.urlEncode(text))
        if r.code == 429 { throw HttpError(t("Google: demasiadas traducciones, espera un momento")) }
        if !r.ok { throw HttpError("Google HTTP \(r.code)") }
        guard let root = try? JSONSerialization.jsonObject(with: r.body) as? [Any], let segs = root.first as? [Any] else {
            throw HttpError("Google: " + t("respuesta inválida"))
        }
        var sb = ""
        for seg in segs { if let a = seg as? [Any], let s = a.first as? String { sb += s } }
        if root.count > 2, let src = root[2] as? String, src.lowercased().hasPrefix(String(lang.prefix(2))) {
            return outgoing ? text : ""        // already in that language
        }
        return sb.trimmed
    }

    private static func openai(_ text: String, _ lang: String, _ outgoing: Bool) throws -> String {
        if Config.openaiKey.isEmpty { throw HttpError(t("Falta la API key de OpenAI (Ajustes)")) }
        let names = ["es": "Spanish", "en": "English", "pt": "Portuguese", "fr": "French", "de": "German",
                     "it": "Italian", "ja": "Japanese", "ru": "Russian", "zh": "Chinese", "ko": "Korean"]
        let ln = names[lang] ?? "Spanish"
        let sys = outgoing
            ? "You are a translator. Translate the user's IRC chat message to \(ln). Rules:\n- Reply ONLY with the translation, no quotes or explanations.\n- Keep nicknames, URLs, emoticons and IRC slang natural.\n- If the message is already in \(ln), reply with the exact original text."
            : "You are a translator. Translate IRC chat messages to \(ln). Rules:\n- Reply ONLY with the translation, no quotes or explanations.\n- If the message is already in \(ln), reply with the exact original text.\n- If the message is a number, URL, IRC command, or completely untranslatable, reply exactly: [SKIP]"
        let body: [String: Any] = [
            "model": Config.openaiModel.ifEmpty("gpt-4o-mini"),
            "max_completion_tokens": 400,
            "messages": [["role": "system", "content": sys], ["role": "user", "content": text]],
        ]
        let r = try Http.call("https://api.openai.com/v1/chat/completions",
                              headers: ["Authorization": "Bearer \(Config.openaiKey)", "Content-Type": "application/json"],
                              body: try JSONSerialization.data(withJSONObject: body))
        if r.code == 401 { throw HttpError(t("OpenAI: API key inválida")) }
        if r.code == 429 { throw HttpError(t("OpenAI: límite de uso alcanzado")) }
        guard let js = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw HttpError("OpenAI \(r.code): " + t("respuesta inválida"))
        }
        if let tokens = (js["usage"] as? [String: Any])?["total_tokens"] as? Int { addUsage(tokens) }
        guard let content = ((js["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String else {
            let err = (js["error"] as? [String: Any])?["message"] as? String ?? t("respuesta inválida")
            throw HttpError(String("OpenAI \(r.code): \(err)".prefix(140)))
        }
        let res = content.trimmed
        return res == "[SKIP]" ? "" : res
    }

    // MARK: - cache and usage on disk

    private static func putCache(_ key: String, _ value: String) {
        lock.lock()
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        while cacheOrder.count > cacheMax { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        lock.unlock()
        let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        func flat(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        let line = "\(parts[0])\t\(flat(parts[1]))\t\(flat(value))\n"
        if let h = try? FileHandle(forWritingTo: cacheFile) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        else { try? line.write(to: cacheFile, atomically: true, encoding: .utf8) }
    }

    private static func loadCache() {
        guard let text = try? String(contentsOf: cacheFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        for l in lines.suffix(cacheMax) {
            let p = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.count >= 3 { let k = p[0] + "\t" + p[1]; if cache[k] == nil { cacheOrder.append(k) }; cache[k] = p[2] }
        }
        // keep the file bounded
        if lines.count > cacheMax * 4 { try? (lines.suffix(cacheMax).joined(separator: "\n") + "\n").write(to: cacheFile, atomically: true, encoding: .utf8) }
    }

    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private static func loadUsage() {
        guard let p = (try? String(contentsOf: usageFile, encoding: .utf8))?.trimmed.split(separator: " ").map(String.init), p.count >= 3 else { return }
        usageDate = p[0]
        usage = (usageDate == today() ? Int(p[1]) ?? 0 : 0, Int(p[2]) ?? 0, p.count > 3 ? Int(p[3]) ?? 0 : 0)
    }

    private static func addUsage(_ tokens: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = today()
        let t0 = now != usageDate ? 0 : usage.today
        usageDate = now
        usage = (t0 + tokens, usage.total + tokens, usage.requests + 1)
        try? "\(now) \(usage.today) \(usage.total) \(usage.requests)\n".write(to: usageFile, atomically: true, encoding: .utf8)
    }
}
