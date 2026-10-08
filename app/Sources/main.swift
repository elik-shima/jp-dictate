// エントリポイント。
//   JPDictate                     メニューバーアプリとして起動
//   JPDictate --transcribe-stdin [--engine apple|kotoba]
//                                 評価用: 標準入力の WAV パスを 1 行ずつ認識し、JSON を 1 行ずつ返す
//                                 ({"text": "...", "ms": 12.3} / {"error": "..."})。貼り付けと同じ後処理を通す。
//                                 エンジンの既定は apple (kotoba はモデルのダウンロード済みが必要)。
import AppKit
import AVFoundation

if CommandLine.arguments.contains("--transcribe-stdin") {
    Log.toStderr = true
    setvbuf(stdout, nil, _IOLBF, 0)
    func emit(_ d: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: d)
        print(String(decoding: data, as: UTF8.self))
    }
    var parsed = EngineKind.apple
    if let i = CommandLine.arguments.firstIndex(of: "--engine") {
        guard i + 1 < CommandLine.arguments.count, let k = EngineKind(rawValue: CommandLine.arguments[i + 1]) else {
            emit(["fatal": "--engine には apple か kotoba を指定してください"]); exit(2)
        }
        parsed = k
    }
    let kind = parsed
    let transcriber: SpeechEngine = kind == .kotoba ? KotobaEngine() : Transcriber()
    Task {
        do {
            try await transcriber.prepare()
        } catch {
            emit(["fatal": error.localizedDescription]); exit(1)
        }
        emit(["ready": true])
        while let line = readLine(strippingNewline: true) {
            let path = line.trimmingCharacters(in: .whitespaces)
            if path.isEmpty { continue }
            let t0 = ProcessInfo.processInfo.systemUptime
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                if file.length == 0 { emit(["text": "", "ms": 0]); continue }
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)) else { throw TranscriberError.convert }
                try file.read(into: buf)
                let text = TextCleaner.clean(try await transcriber.transcribe(try AudioConvert.toMono16k(buf)), whisper: kind == .kotoba)
                emit(["text": text, "ms": ((ProcessInfo.processInfo.systemUptime - t0) * 10000).rounded() / 10])
            } catch {
                emit(["error": error.localizedDescription])
            }
        }
        (transcriber as? KotobaEngine)?.unloadAndWait()  // 終了前に解放する (しないと終了時に Metal 側で異常終了する)
        exit(0)
    }
    dispatchMain()
}

signal(SIGPIPE, SIG_IGN)
// kill / pkill (SIGTERM) でも通常の終了処理を通す (復元待ちのクリップボードを戻す)
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    if NSApp.modalWindow != nil { NSApp.abortModal() }
    NSApp.terminate(nil)
}
sigterm.resume()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
