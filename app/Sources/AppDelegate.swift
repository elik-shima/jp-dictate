// JP Dictate.app — メニューバー常駐の日本語音声入力 (fn を押している間だけ録音 → 離すと貼り付け)。
// 権限 (入力監視・アクセシビリティ・マイク) はこのアプリ自身に与える。
import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateMenuItem = NSMenuItem(title: "起動中…", action: nil, keyEquivalent: "")
    private let noticeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginMenuItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
    private var keyMenuItems: [NSMenuItem] = []
    private var engineMenuItems: [NSMenuItem] = []
    private var switchingEngine = false
    private var lastDownloadPct = -1
    private let menu = NSMenu()
    private let dictation = Dictation()
    private lazy var menubarGlyph: NSImage? = {
        let img = Bundle.main.image(forResource: "MenubarTemplate")  // @2x も自動で読み込まれる
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        return img
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.open()
        buildMenu()
        setState("loading", "")
        Log.write("---- 起動 ----")
        if otherInstanceRunning() {
            setState("error", "JP Dictate がすでに動いています")
            showAlert("JP Dictate がすでに動いています", "このアプリは終了します。") { NSApp.terminate(nil) }
            return
        }
        guard checkPermissions() else { return }
        if TriggerKey.saved == .fn && !SystemState.globeKeyDoesNothing {
            setNotice("⚠️ 🌐キーを押したときの動作が「何もしない」になっていません (システム設定 → キーボード)")
        }
        dictation.onState = { [weak self] s, m in self?.setState(s, m) }
        dictation.onNotice = { [weak self] m in self?.setNotice(m) }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.setState("error", "マイクの許可が必要です")
                    self.showAlert("マイクの許可が必要です",
                                   "システム設定 → プライバシーとセキュリティ → マイク で「JP Dictate」をオンにしてから再起動してください。") {
                        self.openSettings("Privacy_Microphone")
                    }
                    return
                }
                Task { @MainActor in
                    do {
                        try await self.dictation.start()
                        Log.write("準備完了")
                    } catch {
                        Log.write("起動できません: \(error.localizedDescription)")
                        self.setState("error", error.localizedDescription)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.stop()  // 復元待ちのクリップボードを戻す
        Log.write("---- 終了 ----")
    }

    private func otherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// 権限がなくてもイベントタップは作れてしまい、無反応になるだけなので起動時に明示的に確認する
    private func checkPermissions() -> Bool {
        var missing: [String] = []
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess(); missing.append("入力監視") }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess(); missing.append("アクセシビリティ") }
        if missing.isEmpty { return true }
        Log.write("権限がありません: \(missing.joined(separator: ", "))")
        setState("error", "permission:" + missing.joined(separator: ","))
        RunLoop.main.perform(inModes: [.default]) { [weak self] in self?.permissionAlert() }
        return false
    }

    // MARK: - メニュー

    private func buildMenu() {
        stateMenuItem.isEnabled = false
        noticeMenuItem.isEnabled = false
        noticeMenuItem.isHidden = true
        menu.addItem(stateMenuItem)
        menu.addItem(noticeMenuItem)
        menu.addItem(.separator())
        let keyMenu = NSMenu()
        for k in TriggerKey.allCases {
            let item = NSMenuItem(title: k.label, action: #selector(chooseKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k.rawValue
            keyMenu.addItem(item)
            keyMenuItems.append(item)
        }
        let keyItem = NSMenuItem(title: "録音キー", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)
        refreshKeyItems()
        let engineMenu = NSMenu()
        for k in EngineKind.allCases {
            let item = NSMenuItem(title: k.label, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k.rawValue
            engineMenu.addItem(item)
            engineMenuItems.append(item)
        }
        let engineItem = NSMenuItem(title: "認識エンジン", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        refreshEngineItems()
        menu.addItem(NSMenuItem(title: "再起動", action: #selector(relaunch), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "ログを表示", action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "プライバシー設定を開く", action: #selector(openPrivacy), keyEquivalent: ""))
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "JP Dictate を終了", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
        refreshLoginItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItem()  // システム設定側で変更された場合も反映する
    }

    private func setState(_ state: String, _ msg: String) {
        let (symbol, title, tint): (String, String, NSColor?) = {
            switch state {
            case "ready":   return ("mic", "待機中 — \(TriggerKey.saved.shortLabel) を押している間だけ録音", nil)
            case "rec":     return ("mic.fill", "録音中…", .systemRed)
            case "busy":    return ("waveform", "認識中…", nil)
            case "loading": return ("hourglass", "準備中…", nil)
            default:
                let text = msg.hasPrefix("permission:")
                    ? "権限が必要です (\(msg.dropFirst(11).replacingOccurrences(of: ",", with: "・")))"
                    : (msg.isEmpty ? "エラー" : "エラー: \(msg)")
                return ("exclamationmark.triangle", text, .systemOrange)
            }
        }()
        guard let button = statusItem.button else { return }
        if state == "ready" || state == "rec", let glyph = menubarGlyph {
            // 待機中・録音中はアプリのアイコンと同じ形 (減衰振動 → カーソル)。録音中は赤く
            button.image = glyph
            button.contentTintColor = state == "rec" ? .systemRed : nil
        } else {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.contentTintColor = nil
            if let tint {
                button.image = img?.withSymbolConfiguration(.init(paletteColors: [tint]))
            } else {
                img?.isTemplate = true
                button.image = img
            }
        }
        button.toolTip = "JP Dictate — \(title)"
        stateMenuItem.title = title
    }

    private func setNotice(_ msg: String) {
        let short = msg.count > 60 ? String(msg.prefix(60)) + "…" : msg
        noticeMenuItem.title = "最後: \(short)"
        noticeMenuItem.isHidden = msg.isEmpty
    }

    // MARK: - アクション

    /// 権限の変更は起動し直さないと反映されないので、アプリごと起動し直す
    @objc private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func chooseKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = TriggerKey(rawValue: raw) else { return }
        TriggerKey.saved = k
        dictation.hotkey.key = k
        refreshKeyItems()
        setNotice("録音キーを \(k.label) にしました")
        Log.write("録音キー: \(k.rawValue)")
        if stateMenuItem.title.hasPrefix("待機中") { setState("ready", "") }
    }

    private func refreshKeyItems() {
        let current = TriggerKey.saved
        for item in keyMenuItems { item.state = (item.representedObject as? String) == current.rawValue ? .on : .off }
    }

    private func refreshEngineItems() {
        let current = EngineKind.saved
        for item in engineMenuItems { item.state = (item.representedObject as? String) == current.rawValue ? .on : .off }
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = EngineKind(rawValue: raw) else { return }
        guard dictation.started else { setNotice("起動が終わってから切り替えてください"); return }
        guard !switchingEngine, k != dictation.engineKind else { return }
        if k == .kotoba && !KotobaModel.isInstalled {
            // モーダルはランループから出す (showAlert と同じ)
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "kotoba-whisper のモデルをダウンロードしますか？"
                a.informativeText = "約 1.5GB をダウンロードします (初回だけ)。ダウンロードが終わると自動で切り替わります。"
                a.addButton(withTitle: "ダウンロード")
                a.addButton(withTitle: "キャンセル")
                if a.runModal() == .alertFirstButtonReturn { self?.beginSwitch(to: k) }
            }
        } else {
            beginSwitch(to: k)
        }
    }

    /// (必要ならモデルをダウンロードして) エンジンを切り替える。失敗したら前のエンジンのまま、エラーを表示する。
    private func beginSwitch(to k: EngineKind) {
        guard !switchingEngine else { return }
        switchingEngine = true
        setState("loading", "")
        Task { @MainActor in
            do {
                if k == .kotoba && !KotobaModel.isInstalled {
                    lastDownloadPct = -1
                    try await KotobaModel.download { done, total in
                        let pct = total > 0 ? Int(done * 100 / total) : 0
                        DispatchQueue.main.async {
                            guard pct != self.lastDownloadPct else { return }
                            self.lastDownloadPct = pct
                            self.setNotice(total > 0 ? "kotoba-whisper をダウンロード中 \(pct)% (\(done / 1_000_000) / \(total / 1_000_000) MB)"
                                                     : "kotoba-whisper をダウンロード中 \(done / 1_000_000) MB")
                        }
                    }
                    setNotice("kotoba-whisper を読み込み中…")
                }
                try await dictation.switchEngine(to: k)
                setNotice("認識エンジンを \(k.shortLabel) にしました")
            } catch {
                Log.write("認識エンジンを切り替えられません: \(error.localizedDescription)")
                setNotice("⚠️ \(error.localizedDescription)")
                showAlert("認識エンジンを切り替えられません", "\(error.localizedDescription)\n\(dictation.engineKind.shortLabel) のまま使います。")
            }
            switchingEngine = false
            refreshEngineItems()
            dictation.refreshState()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func openPrivacy() {
        openSettings("Privacy_ListenEvent")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            showAlert("ログイン項目を変更できません", error.localizedDescription)
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func permissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "JP Dictate に権限を許可してください"
        a.informativeText = """
        システム設定 → プライバシーとセキュリティ の次の 2 か所で「JP Dictate」をオンにしてください。
          ・入力監視 (fn キーの検知)
          ・アクセシビリティ (カーソル位置への貼り付け)
        許可したら「再起動」を押してください。
        オンになっているのに反映されない場合は、一覧の「JP Dictate」を「−」で削除してから追加し直してください。
        """
        a.addButton(withTitle: "再起動")
        a.addButton(withTitle: "入力監視を開く")
        a.addButton(withTitle: "アクセシビリティを開く")
        a.addButton(withTitle: "あとで")
        switch a.runModal() {
        case .alertFirstButtonReturn: relaunch()
        case .alertSecondButtonReturn: openSettings("Privacy_ListenEvent")
        case .alertThirdButtonReturn: openSettings("Privacy_Accessibility")
        default: break
        }
    }

    /// モーダルはランループから出す (GCD のブロック内だとその間シグナル等が処理されない)
    private func showAlert(_ title: String, _ text: String, then: (() -> Void)? = nil) {
        RunLoop.main.perform(inModes: [.default]) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.runModal()
            then?()
        }
    }
}
