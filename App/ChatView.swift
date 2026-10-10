import SwiftUI
import PhotosUI
import VitaIRCCore

/// What I sent (newest first), for quick replies.
@MainActor enum Sent {
    static var list: [String] = []
    static func add(_ s: String) { list.removeAll { $0 == s }; list.insert(s, at: 0); if list.count > 15 { list.removeLast() } }
}

/// Text asked for in an alert (join a channel, new nick...)
struct InputAsk: Identifiable {
    let id = UUID()
    let title: String
    var initial = ""
    var secure = false
    let onOk: (String) -> Void
}

struct ConfirmAsk: Identifiable { let id = UUID(); let text: String; let onYes: () -> Void }

@MainActor final class Dialogs: ObservableObject {
    static let shared = Dialogs()
    @Published var input: InputAsk?
    @Published var confirm: ConfirmAsk?
    @Published var inputText = ""
    func ask(_ title: String, _ initial: String = "", secure: Bool = false, _ ok: @escaping (String) -> Void) {
        inputText = initial
        input = InputAsk(title: title, initial: initial, secure: secure, onOk: ok)
    }
    func confirm(_ text: String, _ yes: @escaping () -> Void) { confirm = ConfirmAsk(text: text, onYes: yes) }
}

// MARK: - Window list

struct WindowList: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: UiState

    var body: some View {
        List {
            ForEach(model.windows) { w in
                let selected = w.sidx == model.chan?.sidx && w.uid == model.chan?.uid
                Button { model.select(w.sidx, w.uid) } label: { WindowRow(w: w, selected: selected) }
                    .listRowBackground(selected ? C.sel : C.side)
                    .contextMenu { windowMenu(w) }
                    .swipeActions {
                        if w.type != .status {
                            Button(role: .destructive) { Irc.userInput(w.sidx, w.uid, "/close") } label: { Label(t("Cerrar ventana"), systemImage: "xmark") }
                        }
                    }
            }
            if model.windows.isEmpty { Text(t("Sin servidores")).foregroundColor(C.faint) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(C.side)
        .navigationTitle("VitaIRC")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { ui.sheet = .servers } label: { Label(t("Servidores"), systemImage: "server.rack") }
                Spacer()
                Button { ui.sheet = .settings } label: { Label(t("Ajustes"), systemImage: "gearshape") }
            }
        }
    }

    @ViewBuilder func windowMenu(_ w: WinUi) -> some View {
        if w.type == .status {
            let on = w.serverState != .off
            Button { on ? Irc.disconnect(w.sidx) : Irc.connect(w.sidx) } label: {
                Label((on ? t("Desconectar de %s") : t("Conectar a %s")).f(w.name), systemImage: "power")
            }
        } else {
            Button {
                Irc.locked { if w.sidx < Irc.servers.count { Irc.findChanUid(Irc.servers[w.sidx], w.uid)?.muted.toggle() }; History.saveSession(); Irc.dirty() }
            } label: { Label(w.muted ? t("Quitar silencio") : t("Silenciar (sin sonido ni avisos)"), systemImage: "bell.slash") }
            Button(role: .destructive) { Irc.userInput(w.sidx, w.uid, "/close") } label: { Label(t("Cerrar ventana"), systemImage: "xmark") }
        }
    }
}

struct WindowRow: View {
    let w: WinUi
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            if w.type == .status { Circle().fill(C.state(w.serverState)).frame(width: 9, height: 9) }
            else { Spacer().frame(width: 14) }
            let col: Color = w.type == .status ? Color(hex: 0xB0B0C0)
                : (w.muted || (w.type == .channel && !w.joined)) ? C.faint : w.type == .query ? C.pm : C.chan
            Text((w.type == .query ? "@ " : "") + w.name).font(.system(size: fs(16), weight: w.type == .status ? .semibold : .regular))
                .foregroundColor(selected ? (w.type == .query ? C.pm : C.text) : col).lineLimit(1)
            Spacer()
            if w.unread > 0 && !selected {
                Text(w.unread > 99 ? "99" : "\(w.unread)").font(.system(size: fs(12), weight: .semibold)).foregroundColor(C.text)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(w.mention > 0 ? C.err : Color(hex: 0x2A3A5A)))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: UiState
    @State private var showTopic = false

    var body: some View {
        Group {
            if let c = model.chan {
                VStack(spacing: 0) {
                    MessageList(c: c) { ui.msgSheet = $0 }
                    InputBar(c: c)
                }
                .background(C.bg)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar(c) }
                .sheet(item: $ui.msgSheet) { m in MessageSheet(c: c, m: m).environmentObject(model) }
                .alert(c.name, isPresented: $showTopic) { Button("OK") {} } message: { Text(c.topic) }
            } else {
                Text(t("Agrega un servidor desde el menú (△ → Servidores).").replacingOccurrences(of: "(△ → ", with: "(⋯ → "))
                    .foregroundColor(C.dim).padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(C.bg)
            }
        }
    }

    @ToolbarContentBuilder
    func toolbar(_ c: ChanUi) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                let title: String = c.type == .status ? c.serverName : c.type == .query ? "@" + c.name : c.name + (c.muted ? t(" (silenciado)") : "")
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(C.text).lineLimit(1)
                let sub: String = !model.busy.isEmpty ? model.busy
                    : c.type == .status ? "\(c.host) · \(c.nick) · \(stateText(c.state))\(c.away ? t("  ·  ausente") : "")"
                    : c.type == .channel ? t("%d usuarios%s%s").f(c.users.count, c.topic.isEmpty ? "" : "  ·  ", c.topic)
                    : t("privado en %s").f(c.serverName)
                Text(sub).font(.system(size: 11)).lineLimit(1)
                    .foregroundColor(!model.busy.isEmpty ? C.trans : c.state != .online ? C.state(c.state) : C.dim)
                    .onTapGesture { if c.type == .channel && !c.topic.isEmpty { showTopic = true } }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if c.type != .status {
                Button { toggleTranslateIn(c) } label: { Image(systemName: "character.bubble").foregroundColor(c.transIn ? C.trans : C.dim) }
            }
            if c.type == .channel { Button { ui.sheet = .users } label: { Image(systemName: "person.2") } }
            MainMenu(c: c)
        }
    }
}

@MainActor func toggleTranslateIn(_ c: ChanUi) {
    if !Translator.ready() { AppModel.shared.showToast(t("Configura tu API key de OpenAI en Ajustes (o elige el traductor gratis)")); return }
    var on = false
    AppModel.shared.withChan(c) { s, ch in
        ch.transIn.toggle()
        on = ch.transIn
        if ch.transIn {
            // translate the last messages already on screen
            var done = 0
            for m in ch.msgs.reversed() where done < 12 {
                if m.chatty && !m.selfMsg && m.transState == .none && !IrcText.shouldSkipTranslation(m.text) {
                    m.transState = .pending
                    Translator.requestIn(s, ch, m)
                    done += 1
                }
            }
        }
    }
    AppModel.shared.showToast(t("Traducción de recibidos: %s").f(on ? t("activada") : t("desactivada")))
}

struct MessageList: View {
    let c: ChanUi
    let onTap: (MsgUi) -> Void
    @EnvironmentObject var model: AppModel
    @State private var atBottom = true
    @State private var flash: Int64 = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if c.loadingOlder {
                        Text(t("Cargando mensajes anteriores...")).font(.system(size: fs(13))).foregroundColor(C.trans).padding(8)
                    }
                    ForEach(c.msgs) { m in
                        MessageRow(m: m, flash: flash == m.id, onTap: { onTap(m) }) { e in react(c, m, e) }
                            .id(m.id)
                            .onAppear { if m.id == c.msgs.first?.id { requestOlder() } }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .id(c.uid)          // each window keeps its own scroll position
            .environment(\.openURL, OpenURLAction { url in Actions.openLink(url.absoluteString); return .handled })
            .overlay(alignment: .topLeading) {
                if c.msgs.isEmpty { Text(t("Sin mensajes todavía.")).foregroundColor(C.faint).padding() }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "chevron.down").font(.system(size: 18, weight: .bold)).foregroundColor(C.accent)
                            .frame(width: 44, height: 44).background(Circle().fill(C.sel))
                    }.padding(14)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: c.uid) { _ in atBottom = true; DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            // a new message while reading the end: follow it (scrolled up: stay, the ▼ button shows)
            .onChange(of: c.msgs.last?.id) { _ in if atBottom { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } } }
            // search / last mention: scroll there and flash it
            .onChange(of: model.jump?.1) { _ in
                guard let (uid, mid) = model.jump, uid == c.uid else { return }
                withAnimation { proxy.scrollTo(mid, anchor: .center) }
                flash = mid
                model.jump = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { flash = 0 }
            }
        }
    }

    private func requestOlder() {
        Irc.locked { if c.sidx < Irc.servers.count, let ch = Irc.findChanUid(Irc.servers[c.sidx], c.uid) { Irc.requestOlder(Irc.servers[c.sidx], ch) } }
    }
}

@MainActor func react(_ c: ChanUi, _ m: MsgUi, _ emoji: String) {
    Irc.locked {
        guard c.sidx < Irc.servers.count, let ch = Irc.findChanUid(Irc.servers[c.sidx], c.uid), let msg = ch.findMsg(m.id) else { return }
        Irc.sendReact(Irc.servers[c.sidx], ch, msg, emoji)
    }
}

// MARK: - Input

struct InputBar: View {
    let c: ChanUi
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: UiState
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var showCamera = false
    @State private var preview: UIImage?
    @FocusState private var focused: Bool

    private var winId: String { "\(c.sidx)/\(c.uid)" }

    var body: some View {
        VStack(spacing: 0) {
            let sugg = completions()
            if !sugg.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sugg, id: \.self) { n in
                            Button {
                                let whole = !text.contains(" ")
                                let base = text.substringBeforeLast(" ")
                                text = (whole ? "" : base + " ") + n + (whole ? ": " : " ")
                            } label: {
                                Text(n).foregroundColor(C.nick(n)).padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(C.sel))
                            }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
            HStack(spacing: 6) {
                if c.type != .status {
                    ImagesMenu(c: c, photo: $photo, showCamera: $showCamera)
                    Button { ui.sheet = .quick } label: { Image(systemName: "arrowshape.turn.up.left").font(.system(size: 19)).foregroundColor(C.dim) }
                        .frame(width: 34, height: 34)
                }
                TextField(hint, text: $text)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20).fill(C.bg))
                    .foregroundColor(C.text)
                Button { send() } label: { Image(systemName: "paperplane.fill").font(.system(size: 20)).foregroundColor(C.accent) }
                    .frame(width: 38, height: 38)
                    .accessibilityLabel(t("Enviar"))
            }
            .padding(8)
        }
        .background(C.panel)
        .onAppear { text = c.draft }
        .onChange(of: c.uid) { _ in text = c.draft }
        .onChange(of: text) { v in model.saveDraft(c.sidx, c.uid, v) }
        .onChange(of: model.draftOverride?.1) { _ in
            if let (w, _, d) = model.draftOverride, w == winId { text = d; focused = true }
        }
        .onChange(of: photo) { item in
            guard let item = item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { preview = img }
                photo = nil
            }
        }
        .sheet(isPresented: $showCamera) { CameraPicker { img in preview = img } .ignoresSafeArea() }
        .sheet(item: Binding(get: { preview.map { PreviewItem(image: $0) } }, set: { if $0 == nil { preview = nil } })) { p in
            UploadPreview(image: p.image, sidx: c.sidx, uid: c.uid) { preview = nil }
        }
    }

    private var hint: String {
        c.type == .status ? t("Comando (/join #canal)") : c.transOut ? t("Escribir (se envía en %s)").f(Config.langOut) : t("Escribir mensaje...")
    }

    private func send() {
        // pasted text with several lines goes out one line at a time
        let lines = text.components(separatedBy: .newlines).map { $0.trimmed }.filter { !$0.isEmpty }
        for l in lines { Sent.add(l); Irc.userInput(c.sidx, c.uid, l) }
        if !lines.isEmpty { text = ""; model.saveDraft(c.sidx, c.uid, "") }
        focused = true
    }

    /// Nicks matching "@ab" at the end of the input.
    private func completions() -> [String] {
        let w = text.substringAfterLast(" ")
        guard w.hasPrefix("@"), w.count >= 2 else { return [] }
        let frag = String(w.dropFirst())
        let pool = c.type == .query ? [c.name] : c.users.map { $0.nick }
        return Array(pool.filter { $0.lowercased().hasPrefix(frag.lowercased()) }.prefix(12))
    }
}

struct PreviewItem: Identifiable { let id = UUID(); let image: UIImage }

struct ImagesMenu: View {
    let c: ChanUi
    @Binding var photo: PhotosPickerItem?
    @Binding var showCamera: Bool
    @EnvironmentObject var ui: UiState
    @State private var pick = false

    var body: some View {
        Menu {
            Button { if ready() { pick = true } } label: { Label(t("Subir imagen (%s)...").f(Uploader.hostName(Config.imgHost)), systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { if ready() { showCamera = true } } label: { Label(t("Tomar foto con la cámara y subirla"), systemImage: "camera") }
            }
            Button { ui.sheet = .uploads } label: { Label(t("Mis subidas recientes"), systemImage: "clock.arrow.circlepath") }
            Button { ui.sheet = .booru } label: { Label(t("Buscar imágenes (Safebooru, Danbooru, Sankaku)"), systemImage: "photo.stack") }
            Button { ui.sheet = .links } label: { Label(t("Enlaces e imágenes del canal"), systemImage: "link") }
        } label: {
            Image(systemName: "photo.badge.plus").font(.system(size: 19)).foregroundColor(C.dim).frame(width: 34, height: 34)
        }
        .photosPicker(isPresented: $pick, selection: $photo, matching: .images)
    }

    private func ready() -> Bool {
        if let why = Uploader.notReady(c.sidx) { AppModel.shared.showToast(why); return false }
        return true
    }
}

/// Shows the picked photo and uploads it (as JPEG, at most 4096 px).
struct UploadPreview: View {
    let image: UIImage
    let sidx: Int
    let uid: Int64
    let close: () -> Void
    var body: some View {
        NavigationStack {
            Image(uiImage: image).resizable().scaledToFit().padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(C.bg)
                .navigationTitle(t("Vista previa")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(t("Cancelar"), action: close) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(t("Subir a %s").f(Uploader.hostName(Config.imgHost))) {
                            let data = UploadPreview.jpeg(image)
                            let name = "foto_" + {
                                let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f.string(from: Date())
                            }() + ".jpg"
                            Uploader.upload(sidx, uid, UploadSource(name: name, mime: "image/jpeg", data: data))
                            AppModel.shared.showToast(t("Subiendo imagen..."))
                            close()
                        }
                    }
                }
        }
    }

    static func jpeg(_ img: UIImage) -> Data {
        let maxSide: CGFloat = 4096
        var i = img
        let s = max(img.size.width, img.size.height)
        if s > maxSide {
            let k = maxSide / s
            let size = CGSize(width: img.size.width * k, height: img.size.height * k)
            i = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        }
        return i.jpegData(compressionQuality: 0.88) ?? Data()
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss
    func makeCoordinator() -> Coord { Coord(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.done(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { parent.dismiss() }
    }
}
