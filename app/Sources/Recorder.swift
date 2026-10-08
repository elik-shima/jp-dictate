// マイク入力。既定では fn を押している間だけマイクを開く (マイク使用中の表示も録音中だけ出る)。
// JPD_MIC_ALWAYS_ON=1 のときは常に開いておき、キーを押す前の音声 (pre-roll) もリングバッファに保持する
// (話し始めが欠けにくいが、マイク使用中の表示が出続ける)。
// マイクの抜き差し・既定デバイスの切り替えは AVAudioEngine の構成変更通知で開き直し、
// 常時オンのときは、コールバックが止まった場合に watchdog() で開き直し、長時間操作がなければ一時停止する。
import AVFoundation
import Foundation

final class Recorder: @unchecked Sendable {
    static let prerollSeconds = 0.25
    /// true: 押している間だけマイクを開く / false: 常に開いておく (pre-roll あり)
    let onDemand = ProcessInfo.processInfo.environment["JPD_MIC_ALWAYS_ON"] != "1"

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames = 0
    private var frames: [AVAudioPCMBuffer] = []
    private var recording = false
    private var nativeFormat: AVAudioFormat?
    private var lastCallback = Date.distantPast
    private(set) var running = false
    private(set) var paused = false
    private var configObserver: NSObjectProtocol?
    var onProblem: ((String) -> Void)?
    var onRecovered: (() -> Void)?

    /// マイクを開いて入力を始める (メインスレッドから呼ぶ)
    func start() throws {
        stopEngine()
        engine = AVAudioEngine()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイクが見つかりません"])
        }
        nativeFormat = fmt
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.receive(buf) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // 通知の中でエンジンを作り直すと、通知を出しているエンジンの処理と競合するので、少し後に回す
            DispatchQueue.main.async {
                guard let self, self.allowRestart() else { return }
                Log.write("マイクの構成が変わったので開き直します")
                self.restart()
            }
        }
        engine.prepare()
        try engine.start()
        lock.lock(); preroll.removeAll(); prerollFrames = 0; lastCallback = Date(); lock.unlock()
        running = true
        paused = false
    }

    private func stopEngine() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private var restartTimes: [Date] = []

    /// 開き直しは 10 秒に 3 回まで (デバイスが不安定なときに開き直しを繰り返さない)
    private func allowRestart() -> Bool {
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 10 }
        guard restartTimes.count < 3 else {
            Log.write("マイクの開き直しが続いているため、しばらく待ちます")
            return false
        }
        restartTimes.append(now)
        return true
    }

    func restart() {
        do {
            try start()
            onRecovered?()
        } catch {
            running = false
            onProblem?("⚠️ マイクを開けません: \(error.localizedDescription)")
        }
    }

    private func receive(_ buf: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
        copy.frameLength = buf.frameLength
        for ch in 0..<Int(buf.format.channelCount) {
            copy.floatChannelData![ch].update(from: buf.floatChannelData![ch], count: Int(buf.frameLength))
        }
        lock.lock(); defer { lock.unlock() }
        lastCallback = Date()
        if recording {
            frames.append(copy)
        } else {
            preroll.append(copy)
            prerollFrames += Int(copy.frameLength)
            let keep = Int(Recorder.prerollSeconds * copy.format.sampleRate)
            while let first = preroll.first, prerollFrames - Int(first.frameLength) >= keep {
                prerollFrames -= Int(first.frameLength)
                preroll.removeFirst()
            }
        }
    }

    /// 1 秒ごとにメインスレッドから呼ぶ: 止まったマイクの開き直しと、無操作時の一時停止・再開
    func watchdog(idleSeconds: Double, idleLimit: Double) {
        if onDemand { return }  // 押している間だけ開くので、見張るものがない
        lock.lock(); let isRecording = recording; let since = Date().timeIntervalSince(lastCallback); lock.unlock()
        if isRecording { return }
        if paused {
            if idleSeconds < 5 { restart() }  // ユーザーが戻ってきたら fn を押す前に再開しておく (話し始めを欠かさない)
            return
        }
        if running, idleLimit > 0, idleSeconds > idleLimit {
            stopEngine()  // 開きっぱなしだと Mac がスリープしない・マイク使用中の表示が消えない
            paused = true
            return
        }
        if !running || since > 1.0 { restart() }
    }

    /// 録音開始。pre-roll のサンプル数 (16kHz 換算) を返す。
    func begin() -> Int {
        if onDemand && !running {
            do { try start() } catch { onProblem?("⚠️ マイクを開けません: \(error.localizedDescription)") }
        } else if paused || !running {
            restart()
        }
        lock.lock(); defer { lock.unlock() }
        frames = preroll
        let n = prerollFrames
        preroll.removeAll()
        prerollFrames = 0
        recording = true
        let rate = nativeFormat?.sampleRate ?? Transcriber.sampleRate
        return Int(Double(n) * Transcriber.sampleRate / rate)
    }

    func cancel() {
        lock.lock(); recording = false; frames.removeAll(); lock.unlock()
        if onDemand { stopEngine() }
    }

    /// 録音終了。16kHz mono の音声を返す。
    func end() -> [Float] {
        lock.lock()
        recording = false
        let bufs = frames
        frames.removeAll()
        lock.unlock()
        if onDemand { stopEngine() }  // 録り終えたらすぐマイクを閉じる
        // 録音中にマイクが切り替わると途中から形式が変わるので、同じ形式が続く区間ごとに変換してつなぐ
        var out: [Float] = []
        var i = 0
        while i < bufs.count {
            let fmt = bufs[i].format
            var j = i
            while j < bufs.count && bufs[j].format == fmt { j += 1 }
            let group = bufs[i..<j]
            let total = group.reduce(0) { $0 + Int($1.frameLength) }
            if let joined = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)) {
                var off = 0
                for b in group {
                    for ch in 0..<Int(fmt.channelCount) {
                        (joined.floatChannelData![ch] + off).update(from: b.floatChannelData![ch], count: Int(b.frameLength))
                    }
                    off += Int(b.frameLength)
                }
                joined.frameLength = AVAudioFrameCount(off)
                out += (try? AudioConvert.toMono16k(joined)) ?? []
            }
            i = j
        }
        return out
    }
}

enum AudioGate {
    /// 30ms ごとの RMS が gate を超える区間の合計秒数 (長く押しても小さな声が消されないように)
    static func voicedSeconds(_ a: [Float], gate: Float = 0.004) -> Double {
        let fr = Int(Transcriber.sampleRate * 0.03)
        guard a.count >= fr else { return 0 }
        var voiced = 0
        a.withUnsafeBufferPointer { p in
            for start in stride(from: 0, to: a.count - fr + 1, by: fr) {
                var s: Float = 0
                for i in start..<start + fr { s += p[i] * p[i] }
                if (s / Float(fr)).squareRoot() > gate { voiced += 1 }
            }
        }
        return Double(voiced) * 0.03
    }
}
