import Foundation

public struct HttpResult {
    public let code: Int
    public let body: Data
    public let contentType: String
    public let finalUrl: String
    public let length: Int64
    public var ok: Bool { (200...299).contains(code) }
    public var text: String { String(decoding: body, as: UTF8.self) }
    public var location: String
}

public struct HttpError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Background work of the app (network, files).
public let appQueue = DispatchQueue(label: "vitairc.work", qos: .userInitiated, attributes: .concurrent)

/// Blocking HTTP for the worker threads, like the Android version: reads at most `max` bytes
/// (enough to tell what a link is) and reports upload progress.
public enum Http {
    nonisolated(unsafe) public static var userAgent = "VitaIRC/1.0 (iPhone)"

    private final class Task: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
        let max: Int
        let insecureHost: String?
        let followRedirects: Bool
        let progress: ((Int64, Int64) -> Void)?
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var redirectLocation = ""
        let done = DispatchSemaphore(value: 0)

        init(max: Int, insecureHost: String?, follow: Bool, progress: ((Int64, Int64) -> Void)?) {
            self.max = max; self.insecureHost = insecureHost; self.followRedirects = follow; self.progress = progress
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            response = r as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            data.append(d)
            if data.count >= max { data = data.prefix(max); dataTask.cancel() }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData sent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress?(totalBytesSent, totalBytesExpectedToSend)
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                        newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if followRedirects { completionHandler(newRequest) } else {
                redirectLocation = r.value(forHTTPHeaderField: "Location") ?? ""
                completionHandler(nil)
            }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didReceive ch: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // a bouncer with its own certificate, already accepted for IRC on that host
            if let h = insecureHost, ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               ch.protectionSpace.host.eqi(h), let trust = ch.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else { completionHandler(.performDefaultHandling, nil) }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if let e = e as NSError?, !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled && data.count >= max) { error = e }
            if response == nil { response = task.response as? HTTPURLResponse }
            done.signal()
        }
    }

    public static func call(_ url: String, headers: [String: String] = [:], body: Data? = nil, method: String? = nil,
                            max: Int = 4 * 1024 * 1024, ua: String? = nil, timeout: TimeInterval = 60,
                            insecureHost: String? = nil, followRedirects: Bool = true,
                            progress: ((Int64, Int64) -> Void)? = nil) throws -> HttpResult {
        guard let u = URL(string: url) else { throw HttpError(t("Red: %s").f("URL")) }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method ?? (body != nil ? "POST" : "GET")
        req.setValue(ua ?? userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = Task(max: max, insecureHost: insecureHost, follow: followRedirects, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: task, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        if let b = body { session.uploadTask(with: req, from: b).resume() } else { session.dataTask(with: req).resume() }
        task.done.wait()
        if let e = task.error, task.response == nil { throw HttpError(t("Red: %s").f(e.localizedDescription)) }
        let r = task.response
        let ct = (r?.value(forHTTPHeaderField: "Content-Type") ?? "").substringBefore(";").trimmed.lowercased()
        let len = Int64(r?.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        return HttpResult(code: r?.statusCode ?? 0, body: task.data, contentType: ct, finalUrl: r?.url?.absoluteString ?? url,
                          length: len, location: task.redirectLocation.ifEmpty(r?.value(forHTTPHeaderField: "Location") ?? ""))
    }

    /// multipart/form-data body
    public static func multipart(_ fields: [(name: String, value: String)], file: (field: String, name: String, mime: String, data: Data)?)
        -> (body: Data, contentType: String) {
        let boundary = "----VitaIRC\(UUID().uuidString)"
        var b = Data()
        for f in fields {
            b.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.name)\"\r\n\r\n\(f.value)\r\n".data(using: .utf8)!)
        }
        if let f = file {
            let safe = f.name.replacingOccurrences(of: "\"", with: "_")
            b.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.field)\"; filename=\"\(safe)\"\r\nContent-Type: \(f.mime)\r\n\r\n".data(using: .utf8)!)
            b.append(f.data)
            b.append("\r\n".data(using: .utf8)!)
        }
        b.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return (b, "multipart/form-data; boundary=\(boundary)")
    }

    public static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Link (or error) of an upload, to put into the input of a window.
public struct UploadResult { public let sidx: Int; public let uid: Int64; public let ok: Bool; public let text: String }
public struct UpdateInfo: Equatable { public let tag: String; public let url: String }

/// Things the background work tells the UI (set by the app; called on any thread).
public enum AppEvents {
    nonisolated(unsafe) public static var toast: (String) -> Void = { _ in }
    nonisolated(unsafe) public static var upload: (UploadResult) -> Void = { _ in }
    nonisolated(unsafe) public static var update: (UpdateInfo) -> Void = { _ in }
    /// Status line shown while something runs in the background ("" when idle)
    nonisolated(unsafe) public static var busy: (String) -> Void = { _ in }
}
