// fn を押している間だけ録音 → 離すと認識 → 貼り付け、の流れを管理する。
// キー・録音・貼り付けはメインスレッド、認識は 1 本の非同期ワーカーで順番に処理する。
import AppKit
import Foundation

final class Dictation {
    static let tailSeconds = 0.2       // キーを離した後に少しだけ録り続ける (語尾の欠け防止。入力は約 0.1 秒ごとの塊で届くのでその分も見込む)
    static let holdMinSeconds = 0.2    // これより短く押しただけのときは何もしない (うっかり触れた場合)
    static let minVoicedSeconds = 0.1  // 発話らしい音がこれ未満なら無音とみなす
    static let maxRecordSeconds = 120.0  // 離したイベントの取りこぼし対策
    static let micIdleSeconds = Double(ProcessInfo.processInfo.environment["JPD_MIC_IDLE_SEC"] ?? "") ?? 300
    static let rmsGate = Float(ProcessInfo.processInfo.environment["JPD_RMS_GATE"] ?? "") ?? 0.004
    static let sounds = ProcessInfo.processInfo.environment["JPD_SOUNDS"] != "0"

    private struct Job {
        let samples: [Float]
        let nPre: Int
        let tPress: TimeInterval
        let tRelease: TimeInterval
        let front: pid_t?
    }

    let recorder = Recorder()
    let paster = Paster()
    let hotkey = HotkeyMonitor()
    var onState: (String, String) -> Void = { _, _ in }
    var onNotice: (String) -> Void = { _ in }

    private var down = false, cancelled = false
    private var tPress: TimeInterval = 0, nPre = 0, front: pid_t?
    private var pending = 0
    private var tail: DispatchWorkItem?
    private var tailJob: (nPre: Int, tPress: TimeInterval, tRelease: TimeInterval, front: pid_t?)?
    private var jobs: AsyncStream<Job>.Continuation?
    private var watchdogTimer: Timer?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // 認識エンジン (メニューで切り替える。認識ワーカーとメインスレッドの両方から触るのでロックで守る)
    private let apple = Transcriber()
    private let kotoba = KotobaEngine()
    private let engineLock = NSLock()
    private var current: SpeechEngine?
    private(set) var started = false
    var engine: SpeechEngine? {
        engineLock.lock(); defer { engineLock.unlock() }
        return current
    }
    var engineKind: EngineKind { engine?.kind ?? EngineKind.saved }
    private func setEngine(_ e: SpeechEngine) -> SpeechEngine? {
        engineLock.lock(); defer { engineLock.unlock() }
        defer { current = e }
        return current
    }
    private func makeEngine(_ k: EngineKind) -> SpeechEngine { k == .kotoba ? kotoba : apple }

    /// エンジンを切り替える。新しいエンジンの準備 (モデルの読み込み) に失敗したら、前のエンジンのまま error を投げる。
    /// 切り替えに成功したら前のエンジンのモデルは解放する。
    func switchEngine(to k: EngineKind) async throws {
        let new = makeEngine(k)
        try await new.prepare()
        if let old = setEngine(new), old !== new { old.unload() }
        EngineKind.saved = k
        Log.write("認識エンジン: \(k.rawValue)")
    }

    /// 現在の状態 (待機中・録音中・認識中) をメニューに反映し直す
    func refreshState() { idle() }

    /// マイクを開き、音声認識を準備し、fn の監視を始める (権限は呼び出し側で確認済みであること)。
    /// メインスレッドで動かす (Timer やメニューの更新はメインスレッドでないと働かない)。
    @MainActor
    func start() async throws {
        recorder.onProblem = { [weak self] msg in Log.write(msg); self?.onNotice(msg) }
        recorder.onRecovered = { Log.write("マイクを開き直しました") }
        if !recorder.onDemand {
            do { try recorder.start() } catch { onNotice("⚠️ マイクを開けません: \(error.localizedDescription)") }
        }
        // 前回選んだエンジンで始める。kotoba を読み込めないとき (モデルがない等) は Apple 内蔵で始めて、選択も戻す。
        // Apple 内蔵の準備にも失敗したとき (オフラインでの初回起動など) は、次の発話のときにもう一度準備する
        let saved = EngineKind.saved
        do {
            try await switchEngine(to: saved)
        } catch {
            Log.write("\(saved.shortLabel) の準備に失敗: \(error.localizedDescription)")
            if saved != .apple { onNotice("⚠️ \(error.localizedDescription)。Apple 内蔵に戻しました") }
            do {
                try await switchEngine(to: .apple)
            } catch {
                _ = setEngine(apple)
                EngineKind.saved = .apple
                onNotice("⚠️ 音声認識の準備に失敗しました (次の入力で再試行します): \(error.localizedDescription)")
            }
        }
        started = true
        let (stream, cont) = AsyncStream<Job>.makeStream()
        jobs = cont
        Task.detached { [weak self] in
            for await job in stream { await self?.process(job) }
        }
        hotkey.onDown = { [weak self] in self?.keyDown() }
        hotkey.onUp = { [weak self] in self?.keyUp() }
        hotkey.onOther = { [weak self] in self?.otherKey() }
        guard hotkey.start() else { throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "キー入力を監視できません"]) }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.watchdog() }
        idle()
    }

    func stop() {
        watchdogTimer?.invalidate()
        paster.flush()
        kotoba.unloadAndWait()  // 終了前に解放する (しないと終了時に Metal 側で異常終了する)
    }

    // MARK: - キー (メインスレッド)

    private func keyDown() {
        flushTail()  // 離してすぐ押し直した場合、前の発話を先に確定させる (新しい録音を横取りしない)
        if down { recorder.cancel() }  // 離したイベントを取りこぼしていた: 前の録音は捨てて押し直しとして扱う
        down = true
        cancelled = false
        front = SystemState.frontmostPID
        nPre = recorder.begin()
        tPress = now  // マイクを開き終えてから測る (開くのにかかった時間を「押していた時間」に含めない)
        play("Tink")
        onState("rec", "")
    }

    private func keyUp() {
        guard down else { return }
        down = false
        if cancelled { idle(); return }
        pending += 1
        tailJob = (nPre, tPress, now, front)
        let work = DispatchWorkItem { [weak self] in self?.flushTail() }
        tail = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Dictation.tailSeconds, execute: work)
        play("Pop")
        onState("busy", "")
    }

    /// 普段の文字入力でもキーごとに呼ばれるので、録音中にキャンセルしたときだけ何かする
    private func otherKey() {
        guard down, !cancelled else { return }
        cancelled = true
        recorder.cancel()
        Log.write("他のキーが押されたためキャンセル")
        idle()
    }

    private func flushTail() {
        guard let j = tailJob else { return }
        tail?.cancel()
        tail = nil
        tailJob = nil
        jobs?.yield(Job(samples: recorder.end(), nPre: j.nPre, tPress: j.tPress, tRelease: j.tRelease, front: j.front))
    }

    private func idle() {
        onState(down ? "rec" : (pending > 0 ? "busy" : "ready"), "")
    }

    private func watchdog() {
        recorder.watchdog(idleSeconds: SystemState.userIdleSeconds, idleLimit: Dictation.micIdleSeconds)
        if down, !cancelled, now - tPress > Dictation.maxRecordSeconds {
            onNotice("⚠️ \(Int(Dictation.maxRecordSeconds)) 秒を超えたので録音を止めました")
            keyUp()
        }
    }

    private func play(_ name: String) {
        guard Dictation.sounds, let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = 0.4
        s.play()
    }

    // MARK: - 認識 (ワーカー)

    private func process(_ job: Job) async {
        await handle(job)
        await MainActor.run {
            self.pending -= 1
            self.idle()
        }
    }

    private func handle(_ job: Job) async {
        let sr = Transcriber.sampleRate
        let hold = job.tRelease - job.tPress
        if hold < Dictation.holdMinSeconds { Log.write("押した時間が短いためスキップ"); return }
        let a = job.samples
        if !a.isEmpty && !a.contains(where: { $0 != 0 }) {
            // マイクの許可がないとエラーにならず、完全な無音が届く
            Log.write("音声が完全に 0 (マイクの許可を確認)")
            await notice("⚠️ マイクの音声が届いていません (マイクの許可を確認)")
            return
        }
        // 押している間だけマイクを開く場合は、開くまでの遅れ (Bluetooth では 0.5 秒以上のことも) を見込んで緩めに判定する
        let got = Double(a.count - job.nPre), expected = (hold + Dictation.tailSeconds) * sr
        if got < (recorder.onDemand ? 0.25 : 0.5) * expected {
            Log.write(String(format: "マイクから音声が届いていません (%.1fs / %.1fs)", got / sr, expected / sr))
            await notice("⚠️ マイクから音声が届いていません")
            if !recorder.onDemand {  // 押している間だけ開く設定では、次に押したときに開き直すので何もしない
                await MainActor.run { self.recorder.restart() }
            }
            if got <= 0 { return }
        }
        if AudioGate.voicedSeconds(a, gate: Dictation.rmsGate) < Dictation.minVoicedSeconds {
            Log.write("無音のためスキップ"); return
        }
        guard let engine else { return }
        let text: String
        do {
            if let t = engine as? Transcriber, !t.isPrepared { try await t.prepare() }  // 起動時に準備できなかった場合
            text = TextCleaner.clean(try await engine.transcribe(a), whisper: engine.kind == .kotoba)
        } catch {
            Log.write("認識エラー: \(error.localizedDescription)")
            await notice("⚠️ 認識エラー: \(error.localizedDescription)")
            if error as? TranscriberError == .timeout { try? await engine.prepare() }
            return
        }
        if text.isEmpty { Log.write("認識結果なし"); return }
        await MainActor.run {
            let ms = Int((self.now - job.tRelease) * 1000)
            let shown = Log.logText ? text : "(\(text.count)文字)"
            let dur = String(format: "%.1fs", Double(a.count) / sr)
            if SystemState.secureInputEnabled {
                Log.write("[\(dur) → \(ms)ms] パスワード入力中のため貼り付けませんでした \(shown)")
                self.onNotice("パスワード入力中のため貼り付けませんでした")
            } else if let f = job.front, let nf = SystemState.frontmostPID, f != nf {
                self.paster.copyOnly(text)
                Log.write("[\(dur) → \(ms)ms] アプリが切り替わったためコピーのみ \(shown)")
                self.onNotice("前面のアプリが変わったため貼り付けずにコピーしました: \(text)")
            } else {
                self.paster.paste(text)
                Log.write("[\(dur) 音声 → \(ms)ms] \(shown)")
                self.onNotice("\(text)  (\(ms)ms)")
            }
        }
    }

    private func notice(_ s: String) async {
        await MainActor.run { self.onNotice(s) }
    }
}
