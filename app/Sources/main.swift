// エントリポイント。
//   JPDictate                     メニューバーアプリとして起動
//   JPDictate --transcribe-stdin  評価用: 標準入力の WAV パスを 1 行ずつ認識し、JSON を 1 行ずつ返す
//                                 ({"text": "...", "ms": 12.3} / {"error": "..."})。貼り付けと同じ後処理を通す。
//   JPDictate --clean-stdin       評価用: 標準入力の文章を 1 行ずつ清書し、JSON を 1 行ずつ返す
//                                 ({"text": "...", "ms": 812.0, "note": "ok"})。API キーは JPD_API_KEY かキーチェーン。
import AppKit
import AVFoundation

if CommandLine.arguments.contains("--clean-stdin") {
    Log.toStderr = true
    setvbuf(stdout, nil, _IOLBF, 0)
    guard let key = ProcessInfo.processInfo.environment["JPD_API_KEY"] ?? APIKeyStore.load() else {
        print("{\"fatal\": \"API key not set\"}"); exit(1)
    }
    Task {
        while let line = readLine(strippingNewline: true) {
            let t0 = ProcessInfo.processInfo.systemUptime
            let r = await Cleanup.run(line, key: key)
            let ms = ((ProcessInfo.processInfo.systemUptime - t0) * 10000).rounded() / 10
            let data = try! JSONSerialization.data(withJSONObject: ["text": r.text, "ms": ms, "note": r.note])
            print(String(decoding: data, as: UTF8.self))
        }
        exit(0)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--transcribe-stdin") {
    Log.toStderr = true
    setvbuf(stdout, nil, _IOLBF, 0)
    func emit(_ d: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: d)
        print(String(decoding: data, as: UTF8.self))
    }
    let transcriber = Transcriber()
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
                let text = TextCleaner.clean(try await transcriber.transcribe(try AudioConvert.toMono16k(buf)))
                emit(["text": text, "ms": ((ProcessInfo.processInfo.systemUptime - t0) * 10000).rounded() / 10])
            } catch {
                emit(["error": error.localizedDescription])
            }
        }
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
