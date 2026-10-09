import SwiftUI
import VitaIRCCore

// MARK: - Servers

private struct Preset { let name: String; let host: String; let port: Int; let ssl: Bool }
private let presets = [
    Preset(name: "Libera.Chat", host: "irc.libera.chat", port: 6697, ssl: true), Preset(name: "OFTC", host: "irc.oftc.net", port: 6697, ssl: true),
    Preset(name: "EFnet", host: "irc.efnet.org", port: 6697, ssl: true), Preset(name: "Rizon", host: "irc.rizon.net", port: 6697, ssl: true),
    Preset(name: "DALnet", host: "irc.dal.net", port: 6697, ssl: true), Preset(name: "hackint", host: "irc.hackint.org", port: 6697, ssl: true),
    Preset(name: "IRCnet", host: "open.ircnet.net", port: 6667, ssl: false), Preset(name: "Undernet", host: "irc.undernet.org", port: 6667, ssl: false),
    Preset(name: "QuakeNet", host: "irc.quakenet.org", port: 6667, ssl: false),
]

struct ServersView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var edit: EditTarget?

    struct EditTarget: Identifiable { let id = UUID(); let idx: Int; let cfg: ServerCfg }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Config.servers.indices, id: \.self) { i in
                    let cfg = Config.servers[i]
                    let st = model.windows.first { $0.sidx == i }?.serverState ?? .off
                    HStack {
                        Circle().fill(C.state(st)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cfg.name).font(.system(size: 16, weight: .semibold)).foregroundColor(C.text)
                            Text("\(cfg.host):\(cfg.port)\(cfg.ssl ? " SSL" : "") · \(cfg.nick)").font(.caption).foregroundColor(C.dim)
                            Text(stateText(st)).font(.caption2).foregroundColor(C.state(st))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { st != .off }, set: { on in on ? Irc.connect(i) : Irc.disconnect(i) })).labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { edit = EditTarget(idx: i, cfg: cfg) }
                    .listRowBackground(C.panel)
                }
                Menu {
                    ForEach(presets.indices, id: \.self) { i in
                        let p = presets[i]
                        Button("\(p.name)  (\(p.host):\(p.port)\(p.ssl ? " SSL" : ""))") {
                            var c = Config.defaultServer(); c.name = p.name; c.host = p.host; c.port = p.port; c.ssl = p.ssl; c.channels = ""
                            edit = EditTarget(idx: -1, cfg: c)
                        }
                    }
                    Button(t("Otro servidor (manual)...")) {
                        var c = Config.defaultServer(); c.name = ""; c.host = ""; c.channels = ""
                        edit = EditTarget(idx: -1, cfg: c)
                    }
                } label: { Label(t("Añadir servidor"), systemImage: "plus.circle").foregroundColor(C.accent) }
                .listRowBackground(C.panel)
            }
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(t("Servidores")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .sheet(item: $edit) { e in EditServerView(idx: e.idx, cfg: e.cfg) }
        }
    }
}

struct EditServerView: View {
    let idx: Int
    @State var cfg: ServerCfg
    @Environment(\.dismiss) var dismiss
    @State private var port = ""

    init(idx: Int, cfg: ServerCfg) { self.idx = idx; _cfg = State(initialValue: cfg); _port = State(initialValue: "\(cfg.port)") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(t("Nombre"), text: $cfg.name)
                    TextField(t("Servidor"), text: $cfg.host, prompt: Text("irc.libera.chat")).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField(t("Puerto"), text: $port).keyboardType(.numberPad)
                    Toggle("SSL/TLS", isOn: $cfg.ssl)
                }
                Section {
                    TextField("Nick", text: $cfg.nick).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(t("Cuenta (usuario)"), text: $cfg.user, prompt: Text(t("(el nick)"))).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(t("Nombre real"), text: $cfg.realname)
                    SecureField(t("Contraseña"), text: $cfg.password)
                    Picker(t("Autenticación"), selection: $cfg.auth) {
                        ForEach(0..<4) { a in Text(ServerCfg.authName(a) ?? t("Automática")).tag(a) }
                    }
                }
                Section {
                    TextField(t("Canales al conectar"), text: $cfg.channels, prompt: Text("#vitasdk,#henkaku")).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle(t("Conectar al iniciar"), isOn: $cfg.autoconnect)
                } footer: {
                    Text(t("Bouncer (soju/ZNC): agrégalo como servidor; los mensajes perdidos llegan con su hora real."))
                }
                if idx >= 0 {
                    Section {
                        Button(t("Eliminar servidor"), role: .destructive) {
                            Dialogs.shared.confirm(t("¿Eliminar el servidor \"%s\"?").f(cfg.name)) {
                                Irc.disconnect(idx)
                                Config.servers.remove(at: idx)
                                Config.save()
                                Irc.syncFromConfig()
                                if Irc.viewSidx >= Config.servers.count { Irc.viewSidx = -1 }
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(idx < 0 ? t("Nuevo servidor") : t("Editar servidor")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(t("Cancelar")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(t("Guardar")) { save() } }
            }
        }
    }

    private func save() {
        cfg.host = cfg.host.trimmed; cfg.nick = cfg.nick.trimmed; cfg.user = cfg.user.trimmed
        if cfg.host.isEmpty || cfg.nick.isEmpty { AppModel.shared.showToast(t("Servidor y nick son obligatorios")); return }
        if cfg.name.isBlank { cfg.name = cfg.host }
        cfg.port = Int(port.filter(\.isNumber).prefix(5)) ?? 0
        if cfg.port <= 0 { cfg.port = cfg.ssl ? 6697 : 6667 }
        let i: Int
        if idx >= 0 { Config.servers[idx] = cfg; i = idx } else { Config.servers.append(cfg); i = Config.servers.count - 1 }
        Config.save()
        Irc.syncFromConfig()
        if idx < 0 || cfg.autoconnect { Irc.connect(i) }
        dismiss()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var tick = 0
    private func changed() { Config.save(); tick += 1 }

    var body: some View {
        NavigationStack {
            Form {
                Section(t("Traducción")) {
                    Picker(t("Traductor"), selection: bind(Config.trProvider) { v in
                        Config.trProvider = v
                        if v == Config.trpOpenAI && Config.openaiKey.isEmpty { model.showToast(t("ChatGPT necesita tu API key de OpenAI (fila siguiente)")) }
                    }) { Text(Translator.providerName(0)).tag(0); Text(Translator.providerName(1)).tag(1) }
                    row(t("API key de OpenAI (ChatGPT)"), masked(Config.openaiKey)) {
                        Dialogs.shared.ask(t("API key de OpenAI (sk-...)"), Config.openaiKey) { Config.openaiKey = $0.trimmed; changed() }
                    }
                    row(t("Modelo"), Config.openaiModel) { Dialogs.shared.ask(t("Modelo (ej: gpt-4o-mini)"), Config.openaiModel) { Config.openaiModel = $0.trimmed; changed() } }
                    Picker(t("Traducir recibidos a"), selection: bind(Config.langIn) { Config.langIn = $0 }) {
                        ForEach(Config.langCodes.indices, id: \.self) { i in Text(Config.langNames[i]).tag(Config.langCodes[i]) }
                    }
                    Picker(t("Traducir mis mensajes a"), selection: bind(Config.langOut) { Config.langOut = $0 }) {
                        ForEach(Config.langCodes.indices, id: \.self) { i in Text(Config.langNames[i]).tag(Config.langCodes[i]) }
                    }
                    let u = Translator.usage
                    LabeledContent(t("Uso de OpenAI"), value: t("hoy %ld tokens  ·  total %ld tokens (%ld pedidos)").f(u.today, u.total, u.requests))
                }
                Section(t("Imágenes")) {
                    Picker(t("Servicio de imágenes"), selection: bind(Config.imgHost) { Config.imgHost = $0 }) {
                        ForEach(Uploader.hostNames.indices, id: \.self) { i in Text(Uploader.hostNames[i]).tag(i) }
                    }
                    if Config.imgHost == Config.imgLitterbox {
                        Picker(t("Las imágenes se borran tras"), selection: bind(Config.litterTime) { Config.litterTime = $0 }) {
                            ForEach(Array(["1 hora", "12 horas", "24 horas", "72 horas"].enumerated()), id: \.offset) { Text(t($0.element)).tag($0.offset) }
                        }
                    } else if Config.imgHost == Config.imgImgbb {
                        Picker(t("Las imágenes se borran tras"), selection: bind(Config.imgbbExpire) { Config.imgbbExpire = $0 }) {
                            ForEach(Array(["nunca", "1 hora", "1 día", "1 semana", "1 mes"].enumerated()), id: \.offset) { Text(t($0.element)).tag($0.offset) }
                        }
                    }
                    row(t("API key de ImgBB"), masked(Config.imgbbKey)) { Dialogs.shared.ask(t("API key de ImgBB (api.imgbb.com)"), Config.imgbbKey) { Config.imgbbKey = $0.trimmed; changed() } }
                    row(t("Client-ID de Imgur"), Config.imgurId.ifEmpty(t("(sin configurar)"))) { Dialogs.shared.ask(t("Client-ID de Imgur"), Config.imgurId) { Config.imgurId = $0.trimmed; changed() } }
                    Toggle(t("Vista previa de enlaces"), isOn: bind(Config.linkPreviews) { Config.linkPreviews = $0 })
                }
                Section(t("Búsqueda de imágenes")) {
                    Toggle(t("Búsqueda: contenido adulto"), isOn: bind(Config.searchAdult) { on in
                        if !on { Config.searchAdult = false } else {
                            Dialogs.shared.confirm(t("¿Mostrar contenido adulto en búsquedas? Solo si eres mayor de 18.")) {
                                Config.searchAdult = true; changed()
                                model.showToast(t("Contenido para adultos activado (las búsquedas nuevas lo incluyen)"))
                            }
                        }
                    })
                    row(t("Usuario de Sankaku"), Config.sankakuUser.ifEmpty(t("(opcional)"))) { Dialogs.shared.ask(t("Usuario de Sankaku"), Config.sankakuUser) { Config.sankakuUser = $0.trimmed; changed() } }
                    row(t("Contraseña de Sankaku"), Config.sankakuPassword.isEmpty ? t("(opcional)") : "********") {
                        Dialogs.shared.ask(t("Contraseña de Sankaku"), "", secure: true) { Config.sankakuPassword = $0.trimmed; changed() }
                    }
                }
                Section(t("Chat")) {
                    row(t("Palabras que te avisan"), Config.highlight.ifEmpty(t("(solo tu nick)"))) {
                        Dialogs.shared.ask(t("Palabras separadas por coma (ej: vita,henkaku)"), Config.highlight) { Config.highlight = $0.trimmed; changed() }
                    }
                    row(t("Nicks ignorados"), Config.ignore.ifEmpty(t("(ninguno)"))) {
                        Dialogs.shared.ask(t("Nicks separados por coma (se permite *)"), Config.ignore) { Config.ignore = $0.trimmed; changed() }
                    }
                    Toggle(t("Colores y negritas de IRC"), isOn: bind(Config.ircColors) { Config.ircColors = $0 })
                    Toggle(t("Mostrar entradas/salidas"), isOn: bind(Config.showJoins) { Config.showJoins = $0 })
                    Picker(t("Tamaño de texto"), selection: bind(Config.fontPct) { Config.fontPct = $0 }) {
                        ForEach([85, 100, 115, 130], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Picker(t("Idioma de la interfaz"), selection: bind(Config.uiLang) { Config.uiLang = $0; VitaIRCApp.applyLanguage() }) {
                        Text(t("Automático")).tag(0); Text("Español").tag(1); Text("English").tag(2)
                    }
                }
                Section(t("Notificaciones y conexión")) {
                    Toggle(t("Sonido en privados y menciones"), isOn: bind(Config.sound) { Config.sound = $0 })
                    Toggle(t("Notificaciones de privados y menciones"), isOn: bind(Config.notifications) { Config.notifications = $0 })
                    Text(t("En iPhone la conexión sigue unos segundos al salir de la app. Con un bouncer (soju/ZNC) recibes al volver lo que te perdiste."))
                        .font(.caption).foregroundColor(C.dim)
                }
                Section(t("Acerca de")) {
                    if let u = model.update {
                        Button(t("¡%s disponible! Pulsa para ver cómo instalarla").f(u.tag)) { Actions.browser(u.url) }
                    } else {
                        Button(t("Buscar actualizaciones")) { model.showToast(t("Buscando actualizaciones...")); Updates.check(manual: true) }
                    }
                    Toggle(t("Buscar actualizaciones automáticamente"), isOn: bind(Config.updateCheck) { Config.updateCheck = $0 })
                    Button(t("VitaIRC %s  ·  código abierto").f(Updates.appVersion + " iPhone")) { Actions.browser("https://github.com/\(Config.updateRepo)") }
                }
            }
            .id(tick)
            .scrollContentBackground(.hidden).background(C.bg)
            .navigationTitle(t("Ajustes")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }

    private func bind<T>(_ get: @autoclosure @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { set($0); changed(); Irc.dirty() })
    }

    private func row(_ label: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent(label) { Text(value).foregroundColor(C.dim).lineLimit(1) }
        }.foregroundColor(C.text)
    }

    private func masked(_ k: String) -> String { k.isEmpty ? t("(sin configurar)") : String(k.prefix(3)) + "..." + String(k.suffix(4)) }
}

// MARK: - Help

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    private let lines = [
        "Toca la barra de abajo para escribir. Los mensajes que empiezan con / son comandos.",
        "La lista de ventanas tiene servidores, canales y privados. Mantén pulsado uno para silenciarlo o cerrarlo.",
        "Toca un mensaje para responder, abrir un privado, reaccionar, traducirlo, ignorar o copiar.",
        "Escribe @ y el comienzo de un nick: toca la sugerencia para completarlo.",
        "",
        "Comandos: /join #canal  /part  /msg nick texto  /query nick  /me acción  /nick nuevo",
        "/topic texto  /whois nick  /list  /notice  /quote RAW  /connect  /disconnect  /clear  /help",
        "",
        "Traducción: gratis con Google, o con ChatGPT si pones tu API key de OpenAI en Ajustes.",
        "\"Traducir mis mensajes\" envía lo que escribes traducido al idioma de salida.",
        "Imágenes: Litterbox funciona sin cuenta; ImgBB, Imgur o tu soju (FILEHOST) se eligen en Ajustes.",
        "Bouncer (soju/ZNC): agrégalo como servidor; los mensajes perdidos llegan con su hora real.",
        "Usuarios: toca un nick para abrir opciones (privado, ignorar y, si eres operador, op, voz, kick y ban).",
        "",
        "En iPhone la conexión sigue unos segundos al salir de la app. Con un bouncer (soju/ZNC) recibes al volver lo que te perdiste.",
        "Tus ajustes están en la app Archivos → VitaIRC (config.ini, el mismo de la Vita y Android).",
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(t(lines[i])).font(.system(size: fs(14))).foregroundColor(i < 4 ? C.text : C.dim)
                    }
                }.padding()
            }
            .background(C.bg)
            .navigationTitle(t("Ayuda")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}

// MARK: - Channel browser (/list) with search

struct ChanListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var filter = ""

    private struct Data { let rows: [ListedChan]; let listing: Int; let mask: Bool; let online: Bool; let total: Int }

    private var data: Data {
        _ = model.revision
        return Irc.locked {
            guard let c = model.chan, c.sidx < Irc.servers.count else { return Data(rows: [], listing: 0, mask: false, online: false, total: 0) }
            let s = Irc.servers[c.sidx]
            let exact = (filter.hasPrefix("#") ? "" : "#") + filter
            let rows = s.listed.filter { filter.isEmpty || $0.name.containsi(filter) || $0.topic.containsi(filter) }
                .sorted { a, b in
                    let ea = a.name.eqi(exact), eb = b.name.eqi(exact)
                    return ea != eb ? ea : a.users > b.users
                }
            return Data(rows: rows, listing: s.listing, mask: s.listMask, online: s.state == .online, total: s.listed.count)
        }
    }

    var body: some View {
        NavigationStack {
            let d = data
            List {
                if !filter.isEmpty && !d.mask && d.listing == 2 {
                    Text(t("Este servidor no busca en toda su lista: se filtran solo los canales más grandes.")).font(.caption).foregroundColor(C.faint).listRowBackground(C.bg)
                }
                if d.rows.isEmpty {
                    let guess = ((filter.hasPrefix("#") ? "" : "#") + filter).substringBefore(" ").substringBefore(",")
                    let msg = !d.online ? t("Conéctate primero al servidor.")
                        : d.listing != 2 ? (filter.isEmpty ? t("Esperando la lista del servidor...") : t("Buscando en el servidor..."))
                        : !filter.isEmpty ? t("No hay canales con \"%s\". Pulsa ✕ para entrar a %s (si no existe, se crea).").f(filter, guess).replacingOccurrences(of: "Pulsa ✕", with: t("Toca aquí"))
                        : t("El servidor no devolvió canales.")
                    Text(msg).foregroundColor(C.dim).listRowBackground(C.bg)
                        .onTapGesture {
                            if !filter.isEmpty && d.listing == 2, let c = model.chan { Irc.userInput(c.sidx, c.uid, "/join \(guess)"); dismiss() }
                        }
                }
                ForEach(d.rows, id: \.name) { e in
                    Button {
                        if let c = model.chan { Irc.userInput(c.sidx, c.uid, "/join \(e.name)"); dismiss() }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).font(.system(size: 15, weight: .semibold)).foregroundColor(C.chan)
                                if !e.topic.isEmpty { Text(e.topic).font(.system(size: 13)).foregroundColor(C.dim).lineLimit(2) }
                            }
                            Spacer()
                            Text("\(e.users)").foregroundColor(C.accent)
                        }
                    }.listRowBackground(C.panel)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden).background(C.bg)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: t("Buscar canal (nombre o tema)"))
            .onSubmit(of: .search) { search(query) }
            .onChange(of: query) { v in if v.isEmpty && !filter.isEmpty { search("") } }
            .navigationTitle(t("Canales")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(t("Canales")).font(.headline)
                        Text(filter.isEmpty ? t("%s  ·  %d canales%s").f(model.chan?.serverName ?? "", d.total, d.listing == 1 ? t("  ·  cargando...") : "")
                             : t("%s  ·  \"%s\": %d canales%s").f(model.chan?.serverName ?? "", filter, d.rows.count, d.listing == 1 ? t("  ·  cargando...") : ""))
                            .font(.caption2).foregroundColor(C.dim)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) { Button { search(filter) } label: { Image(systemName: "arrow.clockwise") } }
                ToolbarItem(placement: .cancellationAction) { Button("OK") { dismiss() } }
            }
            .onAppear {
                let q = UiState.shared.chanListQuery
                if !q.isEmpty { UiState.shared.chanListQuery = ""; query = q; search(q) }
                else if d.listing == 0 || d.total == 0 { search("") }
            }
        }
    }

    private func search(_ q: String) {
        filter = q.trimmed
        guard let c = model.chan else { return }
        // the list keeps only the biggest channels: ask the server for the matches
        let mask = String(filter.drop(while: { $0 == "#" })).substringBefore(" ").substringBefore(",")
        Irc.userInput(c.sidx, c.uid, !filter.isEmpty && data.mask ? "/list *\(mask)*" : "/list")
    }
}
