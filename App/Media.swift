import SwiftUI
import AVKit
import Photos
import VitaIRCCore

// MARK: - Image search (Safebooru, Danbooru, Sankaku) and favorites

struct BooruView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var tab = 0
    @State private var query = Booru.state.query
    @State private var open: ImageTarget?

    var body: some View {
        NavigationStack {
            let st = model.booru
            let list = tab == 0 ? st.results : model.favorites
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(t("Resultados")).tag(0)
                    Text(t("Favoritos") + (model.favorites.isEmpty ? "" : " (\(model.favorites.count))")).tag(1)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)
                if tab == 0 {
                    Picker("", selection: Binding(get: { st.engine }, set: { e in
                        Config.searchEngine = e; Config.save()
                        if !st.query.isEmpty || !st.results.isEmpty { Booru.search(e, query) } else { Booru.setEngine(e) }
                    })) { ForEach(Booru.names.indices, id: \.self) { Text(Booru.names[$0]).tag($0) } }
                        .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                        ForEach(list) { p in
                            let fav = model.favorites.contains { $0.key == p.key }
                            ZStack(alignment: .topTrailing) {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        let local = Booru.thumbFile(p)
                                        if tab == 1 && FileManager.default.fileExists(atPath: local.path) {
                                            RemoteImage(url: local.absoluteString, fill: true, maxPixel: 400)
                                        } else {
                                            RemoteImage(url: p.thumbUrl, headers: Booru.imageHeaders(p.engine), fill: true, maxPixel: 400)
                                        }
                                    }
                                    .clipped()
                                if fav { Text("★").foregroundColor(C.accent).padding(5) }
                                if p.rating == "q" || p.rating == "e" {
                                    Text(p.rating == "e" ? "E" : "Q").font(.caption2.bold()).foregroundColor(.white)
                                        .padding(.horizontal, 5).background(C.err).cornerRadius(3).padding(5)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                }
                            }
                            .background(C.panel).cornerRadius(6)
                            .onTapGesture { open = ImageTarget(url: p.viewUrl, page: Booru.pageUrl(p), post: p) }
                            .contextMenu {
                                Button { toggleFav(p) } label: { Label(fav ? t("Quitar favorito") : t("Favorito"), systemImage: fav ? "star.slash" : "star") }
                                Button { saveBooru(p) } label: { Label(t("Guardar"), systemImage: "square.and.arrow.down") }
                            }
                            .onAppear { if tab == 0 && p.key == st.results.last?.key { Booru.more() } }
                        }
                    }.padding(6)
                    if tab == 0 && st.loading && !list.isEmpty { ProgressView().padding() }
                }
                .overlay {
                    if list.isEmpty {
                        let msg = tab == 1 ? t("Aún no tienes favoritos. En los resultados, mantén pulsada una imagen para guardarla.")
                            : st.loading ? t("Buscando...") : !st.error.isEmpty ? st.error : !st.query.isEmpty ? t("Sin resultados.")
                            : t("Escribe etiquetas en inglés y pulsa buscar (ej: scenery cat).")
                        Text(msg).foregroundColor(!st.error.isEmpty && tab == 0 ? C.err : C.dim).multilineTextAlignment(.center).padding(24)
                    }
                }
            }
            .background(C.bg)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: t("Buscar imágenes (etiquetas en inglés, ej: scenery cat)"))
            .onSubmit(of: .search) { tab = 0; Booru.search(Config.searchEngine, query) }
            .navigationTitle(tab == 0 ? t("Buscar imágenes · %s").f(Booru.names[st.engine]) : t("Favoritos")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .fullScreenCover(item: $open) { ImageViewer(target: $0) }
        }
    }
}

/// Adds or removes a favorite, keeping a small thumbnail on the device.
@MainActor func toggleFav(_ p: BPost) {
    if Booru.isFav(p) { Booru.toggleFav(p, thumb: nil); AppModel.shared.showToast(t("Quitada de favoritos")); return }
    appQueue.async {
        var thumb: Data?
        if let r = try? Booru.download(try Booru.fresh(p), p.thumbUrl, max: 4 * 1024 * 1024),
           let img = ImageCache.decode(r.body, 240) { thumb = UIImage(cgImage: img.cgImage!).jpegData(compressionQuality: 0.85) }
        if Booru.toggleFav(p, thumb: thumb) { AppEvents.toast(t("Agregada a favoritos")) }
    }
}

/// Downloads a search result's original and saves it to Photos.
@MainActor func saveBooru(_ p0: BPost) {
    AppModel.shared.showToast(t("Guardando en Fotos..."))
    appQueue.async {
        do {
            let p = try Booru.fresh(p0)
            let data = try Booru.download(p, p.fileUrl).body
            saveToPhotos(data)
        } catch { AppEvents.toast(t("No se pudo guardar: %s").f((error as? HttpError)?.message ?? error.localizedDescription)) }
    }
}

func saveToPhotos(_ data: Data) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
        guard st == .authorized || st == .limited else { AppEvents.toast(t("No se pudo guardar: %s").f(t("sin permiso para Fotos"))); return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }) { ok, err in
            AppEvents.toast(ok ? t("Guardada en %s").f(t("Fotos")) : t("No se pudo guardar: %s").f(err?.localizedDescription ?? ""))
        }
    }
}

// MARK: - Image viewer

struct ImageViewer: View {
    let target: ImageTarget
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var post: BPost?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { _ in
                    RemoteImage(url: post?.viewUrl ?? target.url, headers: post.map { Booru.imageHeaders($0.engine) } ?? [:], maxPixel: 3000)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .gesture(MagnificationGesture()
                            .onChanged { v in scale = min(max(lastScale * v, 1), 8) }
                            .onEnded { _ in lastScale = scale; if scale <= 1 { offset = .zero; lastOffset = .zero } })
                        .simultaneousGesture(DragGesture()
                            .onChanged { v in if scale > 1 { offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) } }
                            .onEnded { _ in lastOffset = offset })
                        .onTapGesture(count: 2) {
                            withAnimation { if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 } }
                            lastScale = scale; lastOffset = offset
                        }
                }
                .background(Color(hex: 0x050508))
                if let p = target.post {
                    let fav = model.favorites.contains { $0.key == p.key }
                    HStack {
                        Button {
                            if let (s, u) = Actions.uploadTarget() {
                                Booru.send(post ?? p, s, u)
                                model.showToast(t("Preparando el enlace..."))
                                UiState.shared.closeAll()
                            } else { model.showToast(t("Abre un canal o privado antes de buscar para poder enviar")) }
                        } label: { Label(t("Enviar al chat"), systemImage: "paperplane") }
                        Spacer()
                        Button { toggleFav(post ?? p) } label: { Label(fav ? t("Quitar favorito") : t("Favorito"), systemImage: fav ? "star.fill" : "star") }
                        Spacer()
                        Button { saveBooru(post ?? p) } label: { Label(t("Guardar"), systemImage: "square.and.arrow.down") }
                    }
                    .padding().background(C.panel)
                }
            }
            .navigationTitle(t("Imagen")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if target.post == nil {
                        Button {
                            appQueue.async { if let r = try? Http.call(target.url, max: 40 * 1024 * 1024), r.ok { saveToPhotos(r.body) } }
                        } label: { Image(systemName: "square.and.arrow.down") }
                        ShareLink(item: URL(string: target.page) ?? URL(string: "https://")!) { Image(systemName: "square.and.arrow.up") }
                    }
                    Button { Actions.browser(target.page) } label: { Image(systemName: "safari") }
                }
            }
            .onAppear {
                post = target.post
                // Sankaku's links expire within the hour: refresh a favorite's before showing it
                if let p = target.post, Booru.expired(p) {
                    appQueue.async { if let np = try? Booru.refresh(p) { DispatchQueue.main.async { post = np } } }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Video

struct VideoView: View {
    let target: VideoTarget
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let p = player { VideoPlayer(player: p) } else { Color.black }
            }
            .background(Color.black)
            .navigationTitle(t("Video")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                ToolbarItem(placement: .navigationBarTrailing) { Button { Actions.browser(target.page) } label: { Image(systemName: "safari") } }
            }
            .onAppear {
                guard let u = URL(string: target.url) else { return }
                let p = AVPlayer(url: u)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
        }
        .preferredColorScheme(.dark)
    }
}
