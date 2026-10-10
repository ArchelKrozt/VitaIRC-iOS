import SwiftUI
import VitaIRCCore

/// Same palette as VitaIRC for PS Vita and Android.
enum C {
    static let bg = Color(hex: 0x0B0B10)
    static let panel = Color(hex: 0x13131C)
    static let side = Color(hex: 0x0E0E15)
    static let line = Color(hex: 0x242432)
    static let sel = Color(hex: 0x1D1D2B)
    static let accent = Color(hex: 0xF5E642)
    static let text = Color(hex: 0xD6D6E0)
    static let dim = Color(hex: 0x707084)
    static let faint = Color(hex: 0x484858)
    static let chan = Color(hex: 0x7AAADE)
    static let pm = Color(hex: 0xE8974C)
    static let err = Color(hex: 0xFF5A6A)
    static let ok = Color(hex: 0x5FC87F)
    static let trans = Color(hex: 0x63C5DA)
    static let notice = Color(hex: 0xC08AE8)
    static let hlBg = Color(hex: 0x3A300C)
    static let part = Color(hex: 0xB08060)

    private static let nickColors: [Color] = [0xFF7B7B, 0x7BD88F, 0x7BB4FF, 0xFFC86B, 0xD08BFF, 0x6BE0D8,
                                              0xFF9BD2, 0xB8E06B, 0xFFA05A, 0x9AA8FF, 0x5AD0A0, 0xE8D070].map { Color(hex: $0) }

    /// Same hash as the Vita (FNV-1a on the lowercase nick), so a nick keeps its colour.
    static func nick(_ n: String) -> Color {
        var h: UInt32 = 2166136261
        for ch in n.prefix(39) {
            let c = ("A"..."Z").contains(ch) ? Character(ch.lowercased()) : ch
            for b in String(c).utf8 { h ^= UInt32(b); h = h &* 16777619 }
        }
        return nickColors[Int(h % UInt32(nickColors.count))]
    }

    static let mirc: [Color] = [0xFFFFFF, 0x8A8A8A, 0x6A7EFF, 0x3FBF3F, 0xFF5555, 0xC0703A, 0xC060E0, 0xFFA030,
                                0xFFFF55, 0x70FF70, 0x30C0C0, 0x70FFFF, 0x7090FF, 0xFF70FF, 0x909090, 0xD0D0D0].map { Color(hex: $0) }

    static func forType(_ t: MsgType) -> Color {
        switch t {
        case .msg, .action: return text
        case .notice: return notice
        case .join: return ok
        case .part, .quit, .kick: return part
        case .error: return err
        case .topic: return accent
        default: return dim
        }
    }

    static func state(_ s: ServerState) -> Color {
        switch s { case .online: return ok; case .off: return faint; case .waiting: return err; default: return accent }
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

/// Text size from the "text size" setting.
func fs(_ base: CGFloat = 15) -> CGFloat { base * CGFloat(Config.fontPct) / 100 }

func stateText(_ s: ServerState) -> String {
    switch s {
    case .connecting: return t("conectando")
    case .registering: return t("registrando")
    case .online: return t("en línea")
    case .waiting: return t("reintentando")
    case .off: return t("desconectado")
    }
}

// MARK: - Images with headers, cache and GIF animation

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var waiting: [String: [(UIImage?) -> Void]] = [:]
    private let lock = NSLock()
    init() { cache.totalCostLimit = 80 * 1024 * 1024 }

    func get(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String, headers: [String: String] = [:], maxPixel: CGFloat = 1600, _ done: @escaping (UIImage?) -> Void) {
        if let i = get(url) { done(i); return }
        lock.lock()
        if waiting[url] != nil { waiting[url]!.append(done); lock.unlock(); return }
        waiting[url] = [done]
        lock.unlock()
        appQueue.async {
            var img: UIImage?
            if url.hasPrefix("file://"), let u = URL(string: url), let d = try? Data(contentsOf: u) { img = ImageCache.decode(d, maxPixel) }
            else if let r = try? Http.call(url, headers: headers, max: 40 * 1024 * 1024, ua: headers["User-Agent"]), r.ok { img = ImageCache.decode(r.body, maxPixel) }
            if img == nil && ProcessInfo.processInfo.environment["VITAIRC_DEMO"] == "1" {
                let r = try? Http.call(url, headers: headers, max: 40 * 1024 * 1024, ua: headers["User-Agent"])
                Demo.log("image failed: \(url) code=\(r?.code ?? -1) type=\(r?.contentType ?? "-") bytes=\(r?.body.count ?? -1)")
            }
            if let i = img { self.cache.setObject(i, forKey: url as NSString, cost: Int(i.size.width * i.size.height * 4 * CGFloat(max(1, i.images?.count ?? 1)))) }
            self.lock.lock()
            let cbs = self.waiting.removeValue(forKey: url) ?? []
            self.lock.unlock()
            DispatchQueue.main.async { cbs.forEach { $0(img) } }
        }
    }

    /// Decodes (downscaled) stills and animated GIFs/WebPs.
    static func decode(_ data: Data, _ maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        if n > 1 {
            var frames: [UIImage] = []
            var dur = 0.0
            for i in 0..<min(n, 150) {
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, 640)] as CFDictionary) else { continue }
                frames.append(UIImage(cgImage: cg))
                let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let g = (p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]) ?? (p?[kCGImagePropertyWebPDictionary] as? [CFString: Any])
                let d = (g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                dur += d < 0.02 ? 0.1 : d
            }
            return frames.isEmpty ? nil : UIImage.animatedImage(with: frames, duration: dur)
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// UIImageView keeps GIFs animated (SwiftUI's Image shows only one frame).
struct AnimatedImage: UIViewRepresentable {
    let image: UIImage
    var mode: UIView.ContentMode = .scaleAspectFit
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = mode
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) { v.image = image; v.contentMode = mode }
}

struct RemoteImage: View {
    let url: String
    var headers: [String: String] = [:]
    var fill = false
    var maxPixel: CGFloat = 1200
    var onFail: (() -> Void)? = nil
    @State private var img: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let i = img {
                if i.images != nil { AnimatedImage(image: i, mode: fill ? .scaleAspectFill : .scaleAspectFit) }
                else { Image(uiImage: i).resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
            } else if failed {
                Image(systemName: "photo").foregroundColor(C.faint)
            } else {
                Rectangle().fill(C.panel)
            }
        }
        .onAppear { start() }
        .onChange(of: url) { _ in img = nil; failed = false; start() }
    }

    private func start() {
        if url.isEmpty { failed = true; return }
        if let i = ImageCache.shared.get(url) { img = i; return }
        ImageCache.shared.load(url, headers: headers, maxPixel: maxPixel) { i in
            if let i = i { img = i } else { failed = true; onFail?() }
        }
    }
}
