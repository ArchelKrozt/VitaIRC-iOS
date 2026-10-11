import SwiftUI
import VitaIRCCore

/// Reactions offered in the message menu (same as the Vita).
let reactEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "🎉", "👀", "✅"]

struct MainMenu: View {
    let c: ChanUi
    @EnvironmentObject var ui: UiState
    @EnvironmentObject var model: AppModel
    private var dialogs: Dialogs { Dialogs.shared }

    var body: some View {
        Menu {
            Section {
                Button { dialogs.ask(t("Unirse a canal (ej: #vitasdk)"), "#") { v in if !v.isBlank && v != "#" { Irc.userInput(c.sidx, c.uid, "/join \(v.trimmed)") } } }
                    label: { Label(t("Unirse a un canal..."), systemImage: "number") }
                Button { dialogs.ask(t("Nick para mensaje privado")) { v in if !v.isBlank { Irc.userInput(c.sidx, c.uid, "/query \(v.trimmed)") } } }
                    label: { Label(t("Mensaje privado..."), systemImage: "person") }
                Button { ui.sheet = .chanList } label: { Label(t("Explorar canales del servidor (/list)"), systemImage: "magnifyingglass.circle") }
            }
            if c.type != .status {
                Section {
                    Menu {
                        Button { toggleTranslateIn(c) } label: {
                            Label(t("Traducir mensajes recibidos → %s: %s").f(c.transLang.ifEmpty(Config.langIn), c.transIn ? "ON" : "OFF"), systemImage: "character.bubble")
                        }
                        Button {
                            if !Translator.ready() { model.showToast(t("Configura tu API key de OpenAI en Ajustes (o elige el traductor gratis)")); return }
                            var on = false
                            model.withChan(c) { _, ch in ch.transOut.toggle(); on = ch.transOut }
                            model.showToast(t("Tus mensajes %s").f(on ? t("se traducirán antes de enviarse") : t("se envían sin traducir")))
                        } label: { Label(t("Traducir mis mensajes → %s: %s").f(Config.langOut, c.transOut ? "ON" : "OFF"), systemImage: "arrow.up.message") }
                        Menu {
                            Button(t("El de Ajustes (global)")) { setLang("") }
                            ForEach(Config.langCodes.indices, id: \.self) { i in Button(Config.langNames[i]) { setLang(Config.langCodes[i]) } }
                        } label: {
                            Label(t("Idioma de traducción de este canal: %s").f(c.transLang.isEmpty ? t("el de Ajustes") : Config.langName(c.transLang)), systemImage: "globe")
                        }
                    } label: { Label(t("Traducción..."), systemImage: "character.bubble") }
                    Button { dialogs.ask(t("Buscar en el canal")) { q in searchChannel(q.trimmed) } } label: { Label(t("Buscar en el canal..."), systemImage: "magnifyingglass") }
                    Button {
                        if let m = c.msgs.last(where: { $0.highlight }) { model.jump = (c.uid, m.id) } else { model.showToast(t("No hay menciones en este canal")) }
                    } label: { Label(t("Ir a la última mención"), systemImage: "at") }
                    Menu {
                        if c.type == .channel {
                            Button { dialogs.ask(t("Nuevo tema del canal"), c.topic) { v in Irc.userInput(c.sidx, c.uid, "/topic \(v)") } } label: { Label(t("Cambiar tema del canal..."), systemImage: "textformat") }
                            if c.joined { Button { Irc.userInput(c.sidx, c.uid, "/part") } label: { Label(t("Salir del canal"), systemImage: "rectangle.portrait.and.arrow.right") } }
                        }
                        Button {
                            var muted = false
                            model.withChan(c) { _, ch in ch.muted.toggle(); muted = ch.muted }
                            model.showToast(muted ? t("%s silenciado").f(c.name) : t("%s ya no está silenciado").f(c.name))
                        } label: { Label(c.muted ? t("Quitar silencio") : t("Silenciar (sin sonido ni avisos)"), systemImage: "bell.slash") }
                        Button { Irc.userInput(c.sidx, c.uid, "/clear") } label: { Label(t("Limpiar ventana"), systemImage: "clear") }
                        Button(role: .destructive) { Irc.userInput(c.sidx, c.uid, "/close") } label: { Label(t("Cerrar ventana"), systemImage: "xmark") }
                    } label: { Label(t("Canal (tema, salir, cerrar)..."), systemImage: "bubble.left.and.bubble.right") }
                }
            } else {
                Button { Irc.userInput(c.sidx, c.uid, "/clear") } label: { Label(t("Limpiar ventana"), systemImage: "clear") }
            }
            Section {
                Button { dialogs.ask(t("Nuevo nick"), c.nick) { v in if !v.isBlank { Irc.userInput(c.sidx, c.uid, "/nick \(v.trimmed)") } } }
                    label: { Label(t("Cambiar nick..."), systemImage: "person.text.rectangle") }
                if c.away {
                    Button { Irc.userInput(c.sidx, c.uid, "/back") } label: { Label(t("Volver (quitar ausente)"), systemImage: "eye") }
                } else {
                    Button { dialogs.ask(t("Motivo de ausencia"), t("Ausente")) { v in Irc.userInput(c.sidx, c.uid, "/away \(v.isBlank ? t("Ausente") : v)") } }
                        label: { Label(t("Marcar como ausente..."), systemImage: "eye.slash") }
                }
                let on = c.state != .off
                Button { on ? Irc.disconnect(c.sidx) : Irc.connect(c.sidx) } label: {
                    Label((on ? t("Desconectar de %s") : t("Conectar a %s")).f(c.serverName), systemImage: "power")
                }
            }
            Section {
                Button { ui.sheet = .servers } label: { Label(t("Servidores..."), systemImage: "server.rack") }
                Button { ui.sheet = .settings } label: { Label(t("Ajustes (traducción, imágenes...)"), systemImage: "gearshape") }
                Button { ui.sheet = .help } label: { Label(t("Ayuda y controles"), systemImage: "questionmark.circle") }
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private func setLang(_ code: String) {
        model.withChan(c) { _, ch in ch.transLang = code }
        model.showToast(t("%s se traducirá a %s").f(c.name, Config.langName(code.ifEmpty(Config.langIn))))
    }

    private func searchChannel(_ q: String) {
        if q.isEmpty { return }
        let hits = Array(c.msgs.filter { $0.type != .date && ($0.text.containsi(q) || ($0.trans?.containsi(q) ?? false)) }.suffix(30).reversed())
        if hits.isEmpty { model.showToast(t("Sin resultados para \"%s\"").f(q)); return }
        UiState.shared.choose = ChooseAsk(title: t("Resultados para \"%s\"").f(q),
                                          items: hits.map { "\($0.time) \($0.nick)\($0.nick.isEmpty ? "" : ": ")\($0.text)" }) { i in
            model.jump = (c.uid, hits[i].id)
        }
    }
}

/// A list to pick one item from (search results, languages...)
struct ChooseAsk: Identifiable { let id = UUID(); let title: String; let items: [String]; let onPick: (Int) -> Void }

struct ChooseSheet: View {
    let ask: ChooseAsk
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List(ask.items.indices, id: \.self) { i in
                Button { dismiss(); ask.onPick(i) } label: { Text(ask.items[i]).foregroundColor(C.text).lineLimit(3) }
                    .listRowBackground(C.panel)
            }
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(ask.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(t("Cancelar")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Message

struct MessageSheet: View {
    let c: ChanUi
    let m: MsgUi
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if m.canReact {
                    HStack {
                        ForEach(reactEmojis, id: \.self) { e in
                            let mine = m.reacts.contains { $0.emoji == e && $0.mine }
                            Text(e).font(.system(size: 26)).padding(3)
                                .background(RoundedRectangle(cornerRadius: 8).fill(mine ? Color(hex: 0x3A3410) : .clear))
                                .onTapGesture { react(c, m, e); dismiss() }
                            if e != reactEmojis.last { Spacer(minLength: 0) }
                        }
                    }.listRowBackground(C.panel)
                }
                Section {
                    ForEach(IrcText.urls(m.text, max: 4), id: \.self) { u in
                        let media = Previews.kindOf(u) != .page
                        item((media ? t("Ver imagen:") : t("Abrir en el navegador:")) + " " + u, "link") { Actions.openLink(u) }
                    }
                    if m.chatty && !m.nick.isEmpty && !m.selfMsg {
                        item(t("Responder a %s").f(m.nick), "arrowshape.turn.up.left") { startReply(c, m) }
                        item(t("Ver perfil y WHOIS de %s").f(m.nick), "person.crop.circle") { UiState.shared.userCard = UserCardTarget(sidx: c.sidx, nick: m.nick) }
                        item(t("Mensaje privado a %s").f(m.nick), "person") { Irc.userInput(c.sidx, c.uid, "/query \(m.nick)") }
                        let ign = Irc.isIgnored(m.nick)
                        item((ign ? t("Dejar de ignorar a %s") : t("Ignorar a %s")).f(m.nick), "hand.raised") {
                            Irc.userInput(c.sidx, c.uid, (ign ? "/unignore " : "/ignore ") + m.nick)
                        }
                    }
                    if m.chatty && m.transState != .done && !IrcText.shouldSkipTranslation(m.text) {
                        item(t("Traducir este mensaje"), "character.bubble") {
                            if !Translator.ready() { model.showToast(t("Configura tu API key de OpenAI en Ajustes (o elige el traductor gratis)")); return }
                            model.withChan(c) { s, ch in
                                if let msg = ch.findMsg(m.id) { msg.transState = .pending; Translator.requestIn(s, ch, msg, onDemand: true) }
                            }
                        }
                    }
                    item(t("Copiar texto"), "doc.on.doc") { UIPasteboard.general.string = m.text }
                }
            }
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(m.nick.isEmpty ? t("Mensaje") : m.nick).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Text(m.text).font(.system(size: fs(14))).foregroundColor(C.dim).lineLimit(3).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func item(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { action() } } label: {
            Label(label, systemImage: icon).foregroundColor(C.text).lineLimit(2)
        }.listRowBackground(C.panel)
    }
}

// MARK: - Sheets of the chat

struct UsersSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var user: UserUi?

    var body: some View {
        NavigationStack {
            if let c = model.chan {
                List(c.users) { u in
                    Button {
                        // the user's card (WHOIS and profile); operators keep the long-press menu
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { UiState.shared.userCard = UserCardTarget(sidx: c.sidx, nick: u.nick) }
                    } label: {
                        HStack {
                            Text((u.prefix.map(String.init) ?? "") + u.nick).foregroundColor(u.away ? C.dim : C.nick(u.nick))
                            if u.away { Text("(" + t("ausente") + ")").foregroundColor(C.faint).font(.caption) }
                        }
                    }
                    .listRowBackground(C.panel)
                    .contextMenu { Button { user = u } label: { Label(t("Más opciones..."), systemImage: "ellipsis") } }
                }
                .scrollContentBackground(.hidden).background(C.bg)
                .navigationTitle(t("Usuarios del canal (%d)").f(c.users.count)).navigationBarTitleDisplayMode(.inline)
                .confirmationDialog(user?.nick ?? "", isPresented: Binding(get: { user != nil }, set: { if !$0 { user = nil } }), titleVisibility: .visible) {
                    if let u = user { actions(c, u) }
                }
            }
        }
    }

    @ViewBuilder func actions(_ c: ChanUi, _ u: UserUi) -> some View {
        Button(t("Mensaje privado")) { dismiss(); Irc.userInput(c.sidx, c.uid, "/query \(u.nick)") }
        Button(t("Mencionar")) { dismiss(); model.appendToInput(c.sidx, c.uid, "\(u.nick): ") }
        Button("WHOIS") { dismiss(); Irc.userInput(c.sidx, c.uid, "/whois \(u.nick)") }
        let ign = Irc.isIgnored(u.nick)
        Button(ign ? t("Dejar de ignorar") : t("Ignorar")) { Irc.userInput(c.sidx, c.uid, (ign ? "/unignore " : "/ignore ") + u.nick) }
        if let p = c.myPrefix, "~&@%".contains(p) {
            let hasOp = u.prefix.map { "~&@".contains($0) } ?? false
            let hasVoice = u.prefix == "+"
            Button((hasOp ? t("Quitar op a %s") : t("Dar op a %s")).f(u.nick)) { Irc.userInput(c.sidx, c.uid, (hasOp ? "/deop " : "/op ") + u.nick) }
            Button((hasVoice ? t("Quitar voz a %s") : t("Dar voz a %s")).f(u.nick)) { Irc.userInput(c.sidx, c.uid, (hasVoice ? "/devoice " : "/voice ") + u.nick) }
            Button(t("Expulsar (kick)..."), role: .destructive) {
                Dialogs.shared.ask(t("Motivo para expulsar a %s").f(u.nick)) { r in Irc.userInput(c.sidx, c.uid, "/kick \(u.nick) \(r)") }
            }
            Button(t("Banear y expulsar"), role: .destructive) { Irc.userInput(c.sidx, c.uid, "/kickban \(u.nick)") }
        }
    }
}

struct QuickSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            if let c = model.chan {
                let nicks = Array(c.msgs.reversed().filter { ($0.type == .msg || $0.type == .action) && !$0.selfMsg && !$0.nick.isEmpty }
                    .map { $0.nick }.reduce(into: [String]()) { r, n in if !r.contains(where: { $0.eqi(n) }) { r.append(n) } }.prefix(6))
                List {
                    Section {
                        ForEach(nicks, id: \.self) { n in
                            Button { dismiss(); model.appendToInput(c.sidx, c.uid, "\(n): ", replace: true) } label: {
                                Label(t("Responder a %s").f(n), systemImage: "arrowshape.turn.up.left").foregroundColor(C.nick(n))
                            }.listRowBackground(C.panel)
                        }
                    }
                    if !Sent.list.isEmpty {
                        Section(t("— Enviados recientemente —")) {
                            ForEach(Sent.list.prefix(8), id: \.self) { s in
                                Button { dismiss(); model.appendToInput(c.sidx, c.uid, s, replace: true) } label: {
                                    Label(s, systemImage: "clock").foregroundColor(C.text)
                                }.listRowBackground(C.panel)
                            }
                        }
                    }
                    if nicks.isEmpty && Sent.list.isEmpty { Text(t("Sin mensajes todavía.")).foregroundColor(C.faint).listRowBackground(C.panel) }
                }
                .scrollContentBackground(.hidden).background(C.bg)
                .navigationTitle(t("Respuestas rápidas")).navigationBarTitleDisplayMode(.inline)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct UploadsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let list = Uploader.recent()
    var body: some View {
        NavigationStack {
            List {
                if list.isEmpty { Text(t("Todavía no has subido imágenes")).foregroundColor(C.faint).listRowBackground(C.panel) }
                ForEach(list) { u in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            dismiss()
                            if let (s, w) = Actions.uploadTarget() { model.appendToInput(s, w, u.link) } else { UIPasteboard.general.string = u.link }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(u.link).foregroundColor(C.chan).lineLimit(1)
                                Text(verbatim: "\(u.date)  ·  \(u.host)").font(.caption).foregroundColor(C.dim)
                            }
                        }
                        if !u.deleteUrl.isEmpty {
                            Button(t("      borrar esta imagen (se abre en el navegador)").trimmed) { Actions.browser(u.deleteUrl) }
                                .font(.caption).foregroundColor(C.err)
                        }
                    }.listRowBackground(C.panel)
                }
            }
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(t("Mis subidas recientes")).navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct LinksSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            let links: [(String, String)] = {
                var out: [(String, String)] = []
                for m in (model.chan?.msgs ?? []).reversed() {
                    for u in IrcText.urls(m.text) where out.count < 30 { out.append((m.nick.ifEmpty("*"), u)) }
                }
                return out
            }()
            List {
                if links.isEmpty { Text(t("No hay enlaces en los mensajes recientes")).foregroundColor(C.faint).listRowBackground(C.panel) }
                ForEach(links.indices, id: \.self) { i in
                    let (n, u) = links[i]
                    Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Actions.openLink(u) } } label: {
                        HStack {
                            Image(systemName: Previews.kindOf(u) == .page ? "safari" : "photo").foregroundColor(C.dim)
                            VStack(alignment: .leading) {
                                Text(u).foregroundColor(C.chan).lineLimit(1)
                                Text(n).font(.caption).foregroundColor(C.nick(n))
                            }
                        }
                    }.listRowBackground(C.panel)
                }
            }
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(t("Enlaces e imágenes del canal")).navigationBarTitleDisplayMode(.inline)
        }
    }
}
