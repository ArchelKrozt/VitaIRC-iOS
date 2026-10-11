import SwiftUI
import UserNotifications
import AudioToolbox
import VitaIRCCore

@main
struct VitaIRCApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var ui = UiState.shared
    @StateObject private var dialogs = Dialogs.shared
    @Environment(\.scenePhase) private var phase

    /// Interface language: 0 follows the system, 1 Spanish, 2 English.
    static func applyLanguage() {
        switch Config.uiLang {
        case 1: L.english = false
        case 2: L.english = true
        default: L.english = !(Locale.preferredLanguages.first ?? "es").hasPrefix("es")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(ui)
                .environmentObject(dialogs)
                .preferredColorScheme(.dark)
                .tint(C.accent)
        }
        .onChange(of: phase) { p in AppDelegate.phaseChanged(p) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) private static var bgTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Config.setup(dir: docs)
        VitaIRCApp.applyLanguage()
        Http.userAgent = "VitaIRC/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (iPhone)"
        Updates.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

        let model = AppModel.shared
        IrcHooks.changed = { model.changed() }
        IrcHooks.translateIn = { s, c, m in Translator.requestIn(s, c, m) }
        IrcHooks.translateOut = { s, c, text in Translator.requestOut(s, c, text) }
        IrcHooks.translationReady = { Translator.ready() }
        IrcHooks.notify = { s, c, m in AppDelegate.notify(s.idx, c, m) }
        IrcHooks.toast = { s in DispatchQueue.main.async { model.showToast(s) } }
        IrcHooks.beep = { AppDelegate.beep() }
        AppEvents.toast = IrcHooks.toast
        AppEvents.busy = { s in DispatchQueue.main.async { model.busy = s } }
        AppEvents.upload = { r in
            DispatchQueue.main.async {
                if r.ok { model.appendToInput(r.sidx, r.uid, r.text) } else { model.showToast(t("Error al subir: %s").f(r.text)) }
            }
        }
        AppEvents.update = { u in DispatchQueue.main.async { model.update = u } }
        Booru.changed = { model.changed() }

        Translator.start()
        Booru.loadFavorites()
        Irc.syncFromConfig()
        Irc.locked { History.restoreSession() }
        for (i, s) in Config.servers.enumerated() where s.autoconnect { Irc.connect(i) }
        Updates.check(manual: false)

        UNUserNotificationCenter.current().delegate = self
        // the app's own signals (more reliable than SwiftUI's scene phase for the background time)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.enteredBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.willEnterForeground() }
        }
        if ProcessInfo.processInfo.environment["VITAIRC_DEMO"] == "1" { Demo.start() }
        else { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        return true
    }

    nonisolated(unsafe) private static var leftAt: Date?

    /// Only who is on screen (counters and notifications): the background time is handled below.
    @MainActor static func phaseChanged(_ p: ScenePhase) {
        switch p {
        case .active:
            Irc.appVisible = true
            Irc.locked {
                if Irc.viewSidx >= 0, Irc.viewSidx < Irc.servers.count, let c = Irc.findChanUid(Irc.servers[Irc.viewSidx], Irc.viewUid) { c.unread = 0; c.mention = 0 }
                Irc.dirty()
            }
            UIApplication.shared.applicationIconBadgeNumber = 0
        case .background:
            Irc.appVisible = false
        default: break
        }
    }

    /// iOS gives the app some seconds before it suspends it: ask for them and keep the links meanwhile.
    @MainActor static func enteredBackground() {
        Irc.appVisible = false
        leftAt = Date()
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "irc") {
                // time is up: iOS suspends the app now (the links will be checked on return)
                Irc.noteAll(t("iOS suspendió la app: la conexión se revisará al volver"))
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        if !Irc.anyConnected() { return }
        let left = UIApplication.shared.backgroundTimeRemaining
        if bgTask == .invalid {
            Irc.noteAll(t("App en segundo plano: iOS no dio tiempo extra"))
        } else if left < 3600 {
            Irc.noteAll(t("App en segundo plano: iOS da %d s antes de suspenderla").f(Int(left)))
        }
    }

    /// Back in the app: dead links reconnect at once (with a bouncer, what was missed comes back).
    @MainActor static func willEnterForeground() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        if let at = leftAt, Irc.anyConnected() {
            let secs = Int(Date().timeIntervalSince(at))
            if secs >= 5 { Irc.noteAll(t("De vuelta en la app (%d s fuera): revisando la conexión").f(secs)) }
        }
        leftAt = nil
        Irc.resumeCheck()
    }

    /// PM or mention in a window that isn't on screen.
    static func notify(_ sidx: Int, _ c: Chan, _ m: Msg) {
        let title = c.type == .query ? m.nick : "\(m.nick) · \(c.name)"
        let text = m.text
        let id = "\(sidx)/\(c.uid)"
        let uid = c.uid
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .active {
                AppModel.shared.showToast(c.type == .query ? t("PM de %s: %s").f(m.nick, text) : t("%s en %s: %s").f(m.nick, c.name, text))
                beep()
                return
            }
            guard Config.notifications else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.subtitle = Config.servers.indices.contains(sidx) ? Config.servers[sidx].name : ""
            content.sound = Config.sound ? .default : nil
            content.threadIdentifier = id
            content.userInfo = ["sidx": sidx, "uid": uid]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Short chime for mentions while the app is open (like the Vita).
    static func beep() { if Config.sound { AudioServicesPlaySystemSound(1007) } }

    // a notification opens its window
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        if let s = info["sidx"] as? Int, let u = info["uid"] as? Int64 ?? (info["uid"] as? Int).map(Int64.init) {
            DispatchQueue.main.async { AppModel.shared.select(s, u); UiState.shared.closeAll() }
        }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([]) }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: UiState
    @EnvironmentObject var dialogs: Dialogs
    @Environment(\.horizontalSizeClass) var hsize
    @State private var splash = true

    var body: some View {
        ZStack(alignment: .top) {
            if hsize == .regular {
                // iPad and big iPhones in landscape: the window list stays on the left
                HStack(spacing: 0) {
                    NavigationStack { WindowList() }.frame(width: 300)
                    Rectangle().fill(C.line).frame(width: 1)
                    NavigationStack { ChatView() }
                }
            } else {
                NavigationStack {
                    WindowList().navigationDestination(isPresented: $ui.showChat) { ChatView() }
                }
            }
            if let s = model.toast {
                Text(s).font(.system(size: 14)).foregroundColor(C.text).lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x222234).opacity(0.96)))
                    .padding(.top, 54).padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
            }
            if splash { SplashView().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.25), value: model.toast)
        .background(C.bg.ignoresSafeArea())
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { splash = false } } }
        .sheet(item: $ui.sheet) { s in
            Group {
                switch s {
                case .servers: ServersView()
                case .settings: SettingsView()
                case .chanList: ChanListView()
                case .booru: BooruView()
                case .help: HelpView()
                case .users: UsersSheet()
                case .quick: QuickSheet()
                case .uploads: UploadsSheet()
                case .links: LinksSheet()
                case .editServer(let i): EditServerView(idx: i, cfg: Config.servers.indices.contains(i) ? Config.servers[i] : Config.defaultServer())
                }
            }
            .environmentObject(model).environmentObject(ui).environmentObject(dialogs)
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $ui.image) { ImageViewer(target: $0).environmentObject(model) }
        .fullScreenCover(item: $ui.video) { VideoView(target: $0) }
        .sheet(item: $ui.choose) { ChooseSheet(ask: $0).preferredColorScheme(.dark) }
        .alert(dialogs.input?.title ?? "", isPresented: Binding(get: { dialogs.input != nil }, set: { if !$0 { dialogs.input = nil } })) {
            if dialogs.input?.secure == true { SecureField("", text: $dialogs.inputText) }
            else { TextField("", text: $dialogs.inputText).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Button(t("Cancelar"), role: .cancel) { dialogs.input = nil }
            Button("OK") { let a = dialogs.input; dialogs.input = nil; a?.onOk(dialogs.inputText) }
        }
        .alert(dialogs.confirm?.text ?? "", isPresented: Binding(get: { dialogs.confirm != nil }, set: { if !$0 { dialogs.confirm = nil } })) {
            Button("No", role: .cancel) { dialogs.confirm = nil }
            Button(t("Sí")) { let a = dialogs.confirm; dialogs.confirm = nil; a?.onYes() }
        }
        .alert(t("Te invitaron a %s. ¿Unirte?").f(ui.invite?.1 ?? ""), isPresented: Binding(get: { ui.invite != nil }, set: { if !$0 { ui.invite = nil } })) {
            Button("No", role: .cancel) { ui.invite = nil }
            Button(t("Sí")) {
                if let (s, ch) = ui.invite { Irc.userInput(s, Irc.locked { s < Irc.servers.count ? Irc.servers[s].status.uid : 0 }, "/join \(ch)") }
                ui.invite = nil
            }
        }
        .alert(t("Nueva versión %s").f(model.update?.tag ?? ""),
               isPresented: Binding(get: { model.update != nil && ui.updateAsked != model.update?.tag && !splash },
                                    set: { if !$0 { ui.updateAsked = model.update?.tag ?? "" } })) {
            Button(t("Más tarde"), role: .cancel) { ui.updateAsked = model.update?.tag ?? "" }
            Button(t("Ver cómo instalarla")) { ui.updateAsked = model.update?.tag ?? ""; if let u = model.update { Actions.browser(u.url) } }
        } message: { Text(t("Hay una versión nueva de VitaIRC. En iPhone se instala igual que la primera vez (la página explica cómo); tus servidores, ajustes e historial se conservan.")) }
    }
}

/// Shown once when the app starts.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image("Logo").resizable().frame(width: 112, height: 112).clipShape(RoundedRectangle(cornerRadius: 24))
            Text("VitaIRC for iPhone").font(.system(size: 26, weight: .bold)).foregroundColor(C.accent)
            Text(t("versión %s").f(Updates.appVersion)).font(.system(size: 14)).foregroundColor(C.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
    }
}
