import SwiftUI
import AVKit
import PhotosUI
import VitaIRCCore

// MARK: - Avatars

/// A received or own avatar, or a circle with the nick's initial.
struct AvatarView: View {
    let data: Data?
    let nick: String
    var size: CGFloat = 72
    var body: some View {
        Group {
            if let d = data, !d.isEmpty, let img = UIImage(data: d) {
                Image(uiImage: img).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    C.nick(nick).opacity(0.25)
                    Text(String(nick.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .bold)).foregroundColor(C.nick(nick))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(C.nick(nick).opacity(0.6), lineWidth: 2))
    }
}

/// Square center crop, scaled to `side` px, as JPEG (the 64 px one stays small enough for IRC).
func avatarJpeg(_ img: UIImage, side: CGFloat, maxBytes: Int) -> Data {
    let s = min(img.size.width, img.size.height)
    let crop = CGRect(x: (img.size.width - s) / 2, y: (img.size.height - s) / 2, width: s, height: s)
    let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
    let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
        img.draw(in: CGRect(x: -crop.minX * side / s, y: -crop.minY * side / s, width: img.size.width * side / s, height: img.size.height * side / s))
    }
    var q: CGFloat = 0.8
    var d = out.jpegData(compressionQuality: q) ?? Data()
    while d.count > maxBytes && q > 0.2 { q -= 0.1; d = out.jpegData(compressionQuality: q) ?? d }
    return d
}

// MARK: - User card: WHOIS + VitaIRC profile

struct UserCardView: View {
    let target: UserCardTarget
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var open: ImageTarget?

    private var key: String { userKey(target.sidx, target.nick) }

    var body: some View {
        NavigationStack {
            let w = model.whoisCards[key]
            let p = model.profiles[key]
            let failed = model.profileFailed.contains(key)
            ScrollView {
                VStack(spacing: 14) {
                    // header
                    VStack(spacing: 8) {
                        AvatarView(data: p?.avatar, nick: target.nick, size: 96)
                        Text(p?.name.nonEmptyOrNil ?? target.nick).font(.system(size: 22, weight: .bold)).foregroundColor(C.text)
                        HStack(spacing: 6) {
                            Text("@" + target.nick).foregroundColor(C.nick(target.nick))
                            if let a = w?.account, !a.isEmpty { Label(a, systemImage: "checkmark.seal.fill").labelStyle(.titleAndIcon).foregroundColor(C.ok) }
                            if w?.secure == true { Image(systemName: "lock.fill").foregroundColor(C.ok) }
                        }.font(.system(size: 14))
                        if let a = w?.away, !a.isEmpty {
                            Label(t("Ausente: %s").f(a), systemImage: "moon.fill").font(.system(size: 13)).foregroundColor(C.accent)
                        }
                    }
                    .padding(.top, 8)

                    actions

                    // profile
                    card(t("Perfil VitaIRC")) {
                        if let p = p {
                            if p.none { Text(t("No comparte su perfil.")).foregroundColor(C.dim) }
                            else if p.bio.isEmpty { Text(t("Sin biografía.")).foregroundColor(C.dim) }
                            else { Text(p.bio).foregroundColor(C.text).frame(maxWidth: .infinity, alignment: .leading) }
                        } else if failed {
                            Text(t("No usa VitaIRC o no está conectado.")).foregroundColor(C.dim)
                        } else {
                            HStack { ProgressView(); Text(t("Pidiendo su perfil...")).foregroundColor(C.dim) }
                        }
                    }
                    if let favs = p?.favs, !favs.isEmpty {
                        card(t("Imágenes favoritas")) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                                ForEach(favs) { f in FavThumb(f: f) { post in open = ImageTarget(url: post.viewUrl, page: Booru.pageUrl(post), post: post) } }
                            }
                        }
                    }

                    // WHOIS
                    card("WHOIS") {
                        if let w = w {
                            if !w.found { Text(t("No está conectado.")).foregroundColor(C.dim) } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    row(t("Nombre real"), w.realname)
                                    row(t("Dirección"), "\(w.user)@\(w.host)")
                                    if !w.actualHost.isEmpty { row(t("Conecta desde"), w.actualHost) }
                                    row(t("Servidor"), w.server + (w.serverInfo.isEmpty ? "" : " · \(w.serverInfo)"))
                                    if w.idleSecs >= 0 { row(t("Inactivo"), idle(w.idleSecs)) }
                                    if w.signon > 0 { row(t("Conectado desde"), DateFormatter.localizedString(from: TimeUtil.date(w.signon), dateStyle: .medium, timeStyle: .short)) }
                                    if w.oper { row(t("Operador de IRC"), t("Sí")) }
                                    if !w.channels.isEmpty {
                                        Text(t("Canales")).font(.caption).foregroundColor(C.faint)
                                        FlowChips(items: w.channels) { ch in
                                            let name = String(ch.drop { "~&@%+".contains($0) })
                                            Irc.userInput(target.sidx, Irc.locked { target.sidx < Irc.servers.count ? Irc.servers[target.sidx].status.uid : 0 }, "/join \(name)")
                                            dismiss()
                                        }
                                    }
                                }
                            }
                        } else { HStack { ProgressView(); Text(t("Consultando WHOIS...")).foregroundColor(C.dim) } }
                    }
                }
                .padding()
            }
            .background(C.bg)
            .navigationTitle(target.nick).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) { Button { ask() } label: { Image(systemName: "arrow.clockwise") } }
            }
            .onAppear { if model.whoisCards[key] == nil || model.profiles[key] == nil { ask() } }
            .fullScreenCover(item: $open) { ImageViewer(target: $0).environmentObject(model) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func ask() {
        model.profileFailed.remove(key)
        model.profiles[key] = nil
        model.whoisCards[key] = nil
        Irc.whois(target.sidx, target.nick)
        Irc.requestProfile(target.sidx, target.nick)
    }

    @ViewBuilder private var actions: some View {
        let c = model.chan
        HStack(spacing: 10) {
            bigButton(t("Privado"), "bubble.left.fill") { Irc.userInput(target.sidx, c?.uid ?? 0, "/query \(target.nick)"); dismiss() }
            if let c = c, c.type != .status {
                bigButton(t("Mencionar"), "at") { model.appendToInput(c.sidx, c.uid, "\(target.nick): ") }
            }
            let ign = Irc.isIgnored(target.nick)
            bigButton(ign ? t("Dejar de ignorar") : t("Ignorar"), "hand.raised.fill") {
                Irc.userInput(target.sidx, c?.uid ?? 0, (ign ? "/unignore " : "/ignore ") + target.nick)
            }
        }
    }

    private func bigButton(_ label: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 18)); Text(label).font(.system(size: 12)).lineLimit(1) }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
        }.foregroundColor(C.accent)
    }

    private func card<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundColor(C.faint)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 13)).foregroundColor(C.faint).frame(width: 110, alignment: .leading)
            Text(v).font(.system(size: 13)).foregroundColor(C.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func idle(_ s: Int) -> String {
        s < 60 ? t("%d s").f(s) : s < 3600 ? t("%d min").f(s / 60) : s < 86400 ? t("%d h %d min").f(s / 3600, s % 3600 / 60) : t("%d días").f(s / 86400)
    }
}

/// A public favorite of someone's profile: its thumbnail (looked up when not sent).
struct FavThumb: View {
    let f: ProfileFav
    let open: (BPost) -> Void
    @State private var post: BPost?
    @State private var loading = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                let url = post?.thumbUrl ?? f.thumb
                if url.isEmpty { ProgressView() } else { RemoteImage(url: url, headers: Booru.imageHeaders(f.engine), fill: true, maxPixel: 300) }
            }
            .clipped().cornerRadius(6).background(C.sel.cornerRadius(6))
            .onAppear { if f.thumb.isEmpty { fetch(nil) } }
            .onTapGesture { if let p = post { open(p) } else { fetch(open) } }
    }
    private func fetch(_ then: ((BPost) -> Void)?) {
        if loading { return }
        loading = true
        appQueue.async {
            let p = try? Booru.lookup(f.engine, f.id)
            DispatchQueue.main.async {
                loading = false
                post = p
                if let p = p { then?(p) } else if then != nil { AppModel.shared.showToast(t("Esa imagen ya no está disponible")) }
            }
        }
    }
}

/// Tappable chips that wrap (channels of a WHOIS)
struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void
    var body: some View {
        var rows: [[String]] = [[]]
        var width: CGFloat = 0
        for it in items {
            let w = CGFloat(it.count) * 8 + 24
            if width + w > 320 && !rows[rows.count - 1].isEmpty { rows.append([]); width = 0 }
            rows[rows.count - 1].append(it); width += w + 6
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { ch in
                        Button { tap(ch) } label: {
                            Text(ch).font(.system(size: 13)).foregroundColor(C.chan).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(C.sel))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - My profile

struct MyProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = MyProfile.name
    @State private var bio = MyProfile.bio
    @State private var share = MyProfile.share
    @State private var pick: PhotosPickerItem?
    @State private var avatar = (try? Data(contentsOf: MyProfile.avatarBigFile)) ?? MyProfile.avatar
    @State private var tick = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            AvatarView(data: avatar, nick: Config.servers.first?.nick ?? "?", size: 110)
                            PhotosPicker(selection: $pick, matching: .images) { Text(t("Cambiar foto")) }
                            if !avatar.isEmpty {
                                Button(t("Quitar foto"), role: .destructive) {
                                    try? FileManager.default.removeItem(at: MyProfile.avatarFile)
                                    try? FileManager.default.removeItem(at: MyProfile.avatarBigFile)
                                    avatar = Data()
                                }.font(.caption)
                            }
                        }
                        Spacer()
                    }.listRowBackground(Color.clear)
                }
                Section {
                    TextField(t("Nombre para mostrar"), text: $name).onChange(of: name) { v in if v.count > MyProfile.maxName { name = String(v.prefix(MyProfile.maxName)) } }
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField(t("Biografía"), text: $bio, axis: .vertical).lineLimit(3...8)
                            .onChange(of: bio) { v in if v.count > MyProfile.maxBio { bio = String(v.prefix(MyProfile.maxBio)) } }
                        Text("\(bio.count)/\(MyProfile.maxBio)").font(.caption2).foregroundColor(C.faint)
                    }
                    Toggle(t("Compartir mi perfil"), isOn: $share)
                } footer: {
                    Text(t("Tu perfil se guarda solo en este teléfono. Quien use VitaIRC puede pedírtelo por IRC mientras estés conectado; si no lo compartes, solo verán tu nick."))
                }
                Section {
                    let favs = model.favorites
                    if favs.isEmpty {
                        Text(t("Aún no tienes favoritos. En el buscador de imágenes, mantén pulsada una imagen para guardarla.")).foregroundColor(C.dim)
                    }
                    ForEach(favs) { p in
                        HStack {
                            RemoteImage(url: FileManager.default.fileExists(atPath: Booru.thumbFile(p).path) ? Booru.thumbFile(p).absoluteString : p.thumbUrl,
                                        headers: Booru.imageHeaders(p.engine), fill: true, maxPixel: 200)
                                .frame(width: 48, height: 48).clipped().cornerRadius(6)
                            VStack(alignment: .leading) {
                                Text(p.artist.isEmpty ? Booru.names[p.engine] : "🎨 " + p.artist).font(.system(size: 14)).foregroundColor(C.text).lineLimit(1)
                                Text(p.tags).font(.caption).foregroundColor(C.faint).lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { _ = tick; return MyProfile.isPublic(p.key) }, set: { on in
                                if !MyProfile.setPublic(p.key, on) { model.showToast(t("Puedes tener hasta %d favoritos públicos").f(MyProfile.maxFavs)) }
                                tick += 1
                            })).labelsHidden()
                        }
                    }
                } header: {
                    Text(t("Favoritos públicos (%d/%d)").f(MyProfile.publicFavs.count, MyProfile.maxFavs)).id(tick)
                } footer: {
                    Text(t("Los favoritos públicos aparecen en tu perfil; los demás nunca salen del teléfono."))
                }
            }
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(t("Mi perfil")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(t("Guardar")) { save(); dismiss() } } }
            .onChange(of: pick) { item in
                guard let item = item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        let big = avatarJpeg(img, side: 256, maxBytes: 60_000)
                        let small = avatarJpeg(img, side: 64, maxBytes: 3_600)
                        try? big.write(to: MyProfile.avatarBigFile)
                        try? small.write(to: MyProfile.avatarFile)
                        avatar = big
                    }
                    pick = nil
                }
            }
        }
    }

    private func save() {
        MyProfile.name = name.trimmed
        MyProfile.bio = bio.trimmed
        MyProfile.share = share
        MyProfile.save()
        model.showToast(t("Perfil guardado"))
    }
}

// MARK: - Videos in the chat

/// Muted, looping video in the chat (Imgur's "GIFs")
struct LoopingVideo: UIViewRepresentable {
    let url: String
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var looper: AVPlayerLooper?
        var player: AVQueuePlayer?
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        guard let u = URL(string: url) else { return v }
        let q = AVQueuePlayer()
        q.isMuted = true
        v.looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: u))
        v.player = q
        (v.layer as! AVPlayerLayer).player = q
        (v.layer as! AVPlayerLayer).videoGravity = .resizeAspect
        q.play()
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) {}
    static func dismantleUIView(_ v: PlayerView, coordinator: ()) { v.player?.pause() }
}

/// Floating player over the chat: drag it to a corner, tap ⤢ for full screen.
struct MiniPlayer: View {
    let target: VideoTarget
    @EnvironmentObject var ui: UiState
    @State private var player: AVPlayer?
    @State private var pos: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var corner = 3       // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.62, 300), h = w * 9 / 16
            let pad: CGFloat = 12
            let x = corner % 2 == 0 ? pad : geo.size.width - w - pad
            let y = corner < 2 ? pad + 60 : geo.size.height - h - pad - 70
            ZStack(alignment: .topTrailing) {
                Group { if let p = player { VideoPlayer(player: p) } else { Color.black } }
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 6) {
                    Button { let u = target; ui.miniVideo = nil; ui.video = u } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    Button { ui.miniVideo = nil } label: { Image(systemName: "xmark") }
                }
                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                .padding(6).background(Capsule().fill(.black.opacity(0.55))).padding(6)
            }
            .shadow(color: .black.opacity(0.6), radius: 10)
            .position(x: x + w / 2 + pos.width, y: y + h / 2 + pos.height)
            .gesture(DragGesture()
                .onChanged { v in pos = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height) }
                .onEnded { _ in
                    // snap to the nearest corner
                    let cx = x + w / 2 + pos.width, cy = y + h / 2 + pos.height
                    withAnimation(.spring(response: 0.35)) {
                        corner = (cy < geo.size.height / 2 ? 0 : 2) + (cx < geo.size.width / 2 ? 0 : 1)
                        pos = .zero
                    }
                    dragStart = .zero
                })
        }
        .onAppear {
            guard let u = URL(string: target.url) else { return }
            let p = AVPlayer(url: u)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
