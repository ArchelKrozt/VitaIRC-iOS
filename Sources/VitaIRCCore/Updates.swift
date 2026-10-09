import Foundation

/// Looks for a newer release on GitHub (once a day, or when asked). iOS can't install it from
/// the app: the user gets the release page with the instructions.
public enum Updates {
    nonisolated(unsafe) public static var appVersion = "1.0"

    public static func versionCompare(_ a: String, _ b: String) -> Int {
        func nums(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let x = nums(a), y = nums(b)
        for i in 0..<min(max(x.count, y.count, 1), 4) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d }
        }
        return 0
    }

    public static func check(manual: Bool) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        if !manual && (!Config.updateCheck || Config.updateLast == today) { return }
        appQueue.async {
            do {
                let r = try Http.call("https://api.github.com/repos/\(Config.updateRepo)/releases/latest", headers: ["Accept": "application/vnd.github+json"])
                if r.code == 404 { throw HttpError(t("Todavía no hay versiones publicadas")) }
                if !r.ok { throw HttpError("GitHub HTTP \(r.code)") }
                let js = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
                let tag = jstr(js["tag_name"])
                Config.updateLast = today
                Config.save()
                if versionCompare(tag, appVersion) > 0 {
                    AppEvents.update(UpdateInfo(tag: tag, url: jstr(js["html_url"])))
                } else if manual {
                    AppEvents.toast(t("Ya tienes la última versión (%s)").f(appVersion))
                }
            } catch {
                if manual { AppEvents.toast(t("Actualizaciones: %s").f((error as? HttpError)?.message ?? error.localizedDescription)) }
            }
        }
    }
}
