import SwiftUI
import VitaIRCCore

func prefixOf(_ m: MsgUi) -> String {
    switch m.type {
    case .msg: return "\(m.nick) "
    case .action: return "* \(m.nick) "
    case .notice: return "-\(m.nick.ifEmpty("*"))- "
    case .join: return "→ "
    case .part, .quit, .kick: return "← "
    case .error: return "! "
    default: return "· "
    }
}

/// Message text with mIRC colours/bold/underline and tappable links.
func formatText(_ m: MsgUi, _ base: Color) -> AttributedString {
    var a = AttributedString(m.text)
    a.foregroundColor = base
    let n = m.text.count
    func range(_ from: Int, _ to: Int) -> Range<AttributedString.Index>? {
        guard from < to, to <= n else { return nil }
        let s = a.characters.index(a.startIndex, offsetBy: from)
        let e = a.characters.index(a.startIndex, offsetBy: to)
        return s..<e
    }
    if Config.ircColors {
        for (i, sp) in m.spans.enumerated() {
            let end = i + 1 < m.spans.count ? m.spans[i + 1].start : n
            guard let r = range(sp.start, end) else { continue }
            if sp.fg >= 0 { a[r].foregroundColor = C.mirc[sp.fg] }
            if sp.bg >= 0 {
                a[r].backgroundColor = sp.bg == 1 ? Color(hex: 0x101010) : C.mirc[sp.bg]
                if sp.fg < 0 { a[r].foregroundColor = [0, 8, 9, 11, 15].contains(sp.bg) ? .black : base }
            }
            var intent: InlinePresentationIntent = []
            if sp.bold { intent.insert(.stronglyEmphasized) }
            if sp.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { a[r].inlinePresentationIntent = intent }
            if sp.underline { a[r].underlineStyle = .single }
        }
    }
    var from = m.text.startIndex
    for u in IrcText.urls(m.text) {
        guard let r = m.text.range(of: u, range: from..<m.text.endIndex) else { continue }
        let s = m.text.distance(from: m.text.startIndex, to: r.lowerBound)
        if let ar = range(s, s + u.count), let url = URL(string: u) {
            a[ar].link = url
            a[ar].foregroundColor = C.chan
            a[ar].underlineStyle = .single
        }
        from = r.upperBound
    }
    return a
}

/// "Today", "Yesterday" or "Thu 08/10/2026"
func dateLabel(_ ts: Int64) -> String {
    let cal = Calendar.current
    let d = TimeUtil.date(ts)
    if cal.isDateInToday(d) { return t("Hoy") }
    if cal.isDateInYesterday(d) { return t("Ayer") }
    let days = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
    let c = cal.dateComponents([.weekday, .day, .month, .year], from: d)
    return "%s %02d/%02d/%04d".f(t(days[(c.weekday ?? 1) - 1]), c.day ?? 0, c.month ?? 0, c.year ?? 0)
}

struct DateSeparator: View {
    let ts: Int64
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(C.line).frame(height: 1)
            Text(dateLabel(ts)).font(.system(size: fs(13))).foregroundColor(C.dim).fixedSize()
            Rectangle().fill(C.line).frame(height: 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct MessageRow: View {
    let m: MsgUi
    let flash: Bool
    let onTap: () -> Void
    let onReact: (String) -> Void

    var body: some View {
        if m.type == .date { DateSeparator(ts: m.ts) } else { row }
    }

    private var chatty: Bool { m.type == .msg || m.type == .action }
    private var nickColor: Color { m.pending ? C.faint : chatty ? (m.selfMsg ? C.accent : C.nick(m.nick)) : C.forType(m.type) }
    private var textColor: Color { m.pending ? C.faint : C.forType(m.type) }

    private var row: some View {
        let timeW = 44 * CGFloat(Config.fontPct) / 100
        var line = AttributedString(prefixOf(m))
        line.foregroundColor = nickColor
        if chatty { line.inlinePresentationIntent = .stronglyEmphasized }
        line += formatText(m, textColor)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(m.pending ? "···" : m.time).font(.system(size: fs(12))).foregroundColor(C.faint).frame(width: timeW, alignment: .leading)
                Text(line).font(.system(size: fs())).frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                if m.transState == .pending {
                    Text(t("» traduciendo...")).font(.system(size: fs(14))).foregroundColor(C.faint)
                } else if m.transState == .done, let tr = m.trans {
                    Text("» " + tr).font(.system(size: fs(14))).foregroundColor(C.trans)
                }
                if Config.linkPreviews && !m.pending && m.chatty, let u = IrcText.urls(m.text, max: 1).first {
                    LinkPreviewView(url: u).padding(.top, 2)
                }
                if !m.reacts.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(m.reacts, id: \.self) { r in
                            Text(verbatim: "\(r.emoji) \(r.count)").font(.system(size: fs(13))).foregroundColor(r.mine ? C.accent : C.text)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 10).fill(r.mine ? Color(hex: 0x3A3410) : C.sel))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(r.mine ? C.accent : .clear))
                                .onTapGesture { if m.canReact { onReact(r.emoji) } }
                        }
                    }
                }
            }
            .padding(.leading, timeW)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flash ? Color(hex: 0x2A3A5A) : m.highlight ? C.hlBg : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct LinkPreviewView: View {
    let url: String
    @State private var p: LinkPreview?
    @State private var broken = false

    var body: some View {
        Group {
            if let pv = p, !pv.ok { EmptyView() }
            else if let pv = p, pv.kind == .image, !broken {
                RemoteImage(url: pv.media, maxPixel: 700, onFail: { broken = true })
                    .frame(maxWidth: 320, maxHeight: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(C.line))
                    .onTapGesture { Actions.openLink(url) }
            } else { card }
        }
        .onAppear {
            if let c = Previews.cached(url) { p = c; return }
            Previews.load(url) { r in DispatchQueue.main.async { p = r } }
        }
    }

    private var card: some View {
        let video = p != nil && (p!.kind == .video || p!.videoSite)
        let l1: String, l2: String, l3: String
        if let pv = p {
            switch pv.kind {
            case .image: (l1, l2, l3) = (url, t("formato no compatible: toca para abrir en el navegador"), pv.site)
            case .video: (l1, l2, l3) = ("▶ " + pv.title, pv.size > 0 ? t("Video · %.1f MB · toca para reproducir").f(Double(pv.size) / 1048576) : t("Video · toca para reproducir"), pv.site)
            case .page: (l1, l2, l3) = (pv.title.ifEmpty(url), pv.desc, pv.site)
            }
        } else { (l1, l2, l3) = (url, t("cargando vista previa..."), "") }
        return HStack(spacing: 0) {
            Rectangle().fill(video ? C.err : C.accent).frame(width: 3)
            if let pv = p, !pv.image.isEmpty, !broken {
                ZStack {
                    RemoteImage(url: pv.image, fill: true, maxPixel: 300).frame(width: 104, height: 60).clipped().cornerRadius(4)
                    if video { Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(.white, .black.opacity(0.6)) }
                }.padding(6)
            } else { Spacer().frame(width: 10) }
            VStack(alignment: .leading, spacing: 1) {
                Text(l1).font(.system(size: fs(14), weight: .semibold)).foregroundColor(C.text).lineLimit(1)
                if !l2.isEmpty { Text(l2).font(.system(size: fs(13))).foregroundColor(C.dim).lineLimit(1) }
                if !l3.isEmpty { Text(l3).font(.system(size: fs(12))).foregroundColor(C.faint).lineLimit(1) }
            }.padding(.trailing, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520, minHeight: 72, maxHeight: 72)
        .background(C.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { if broken { Actions.browser(url) } else { Actions.openLink(url) } }
    }
}
