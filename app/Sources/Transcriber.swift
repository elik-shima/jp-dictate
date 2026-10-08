// macOS 26 内蔵の音声認識 (SpeechAnalyzer + SpeechTranscriber, ja_JP)。
// モデルは prepare() で一度だけ読み込み、プロセスが生きている間は保持する (modelRetention = .processLifetime)。
// 発話ごとに新しい SpeechAnalyzer を作り、録音した音声をメモリ上のバッファのまま渡す (ディスクに書かない)。
import AVFoundation
import CoreMedia
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case unsupported, noFormat, notPrepared, timeout, convert
    var errorDescription: String? {
        switch self {
        case .unsupported: return "この Mac の音声認識は日本語 (ja_JP) に対応していません"
        case .noFormat: return "音声認識に使える音声フォーマットがありません"
        case .notPrepared: return "音声認識の準備ができていません"
        case .timeout: return "音声認識が応答しません"
        case .convert: return "音声の変換に失敗しました"
        }
    }
}

/// 一度だけ true を返す (競争する 2 つのタスクのどちらか一方だけが結果を返すため)
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 同じ時間区間の結果は新しいもので置き換え、時間順に連結する
private final class Segments: @unchecked Sendable {
    private let lock = NSLock()
    private var segs: [(CMTimeRange, String)] = []
    func add(_ r: CMTimeRange, _ t: String) {
        lock.lock(); defer { lock.unlock() }
        segs.removeAll { s in
            CMTimeCompare(s.0.start, CMTimeRangeGetEnd(r)) < 0 && CMTimeCompare(r.start, CMTimeRangeGetEnd(s.0)) < 0
                || CMTimeCompare(s.0.start, r.start) == 0
        }
        segs.append((r, t))
    }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return segs.sorted { CMTimeCompare($0.0.start, $1.0.start) < 0 }.map { $0.1 }.joined()
    }
}

final class Transcriber: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private let locale = Locale(identifier: "ja_JP")
    private let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    private var format: AVAudioFormat?
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Transcriber.sampleRate,
                                            channels: 1, interleaved: false)!

    private func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// 認識アセットの用意 (未インストールならダウンロード) とモデルの読み込み
    func prepare() async throws {
        let probe = makeModule()
        let status = await AssetInventory.status(forModules: [probe])
        if status == .unsupported { throw TranscriberError.unsupported }
        if status != .installed, let req = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            Log.write("日本語の音声認識アセットを確認しています (未インストールならダウンロード)")
            try await req.downloadAndInstall()
        }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            throw TranscriberError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [probe], options: options)
        try await analyzer.prepareToAnalyze(in: fmt)
        await analyzer.cancelAndFinishNow()
        format = fmt
    }

    var isPrepared: Bool { format != nil }

    /// 16kHz mono の音声を認識する。timeout 秒で打ち切る。
    /// (タスクグループは止まった子タスクの終了を待ってしまうので、先に終わった方だけを 1 回返す形で競わせる。
    ///  時間切れのときは止まった認識を待たずに返し、次の発話は新しい SpeechAnalyzer で処理する)
    func transcribe(_ samples: [Float], timeout: Double = 30) async throws -> String {
        guard let fmt = format else { throw TranscriberError.notPrepared }
        guard !samples.isEmpty else { return "" }
        // 1 つのバッファが長すぎると先頭が捨てられるので、10 秒ずつに分けて渡す
        let chunk = Int(Transcriber.sampleRate * 10)
        let buffers = try stride(from: 0, to: samples.count, by: chunk).map {
            try convert(Array(samples[$0..<min($0 + chunk, samples.count)]), to: fmt)
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            let work = Task {
                do {
                    let text = try await self.run(buffers)
                    if once.claim() { cont.resume(returning: text) }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                if once.claim() {
                    work.cancel()
                    cont.resume(throwing: TranscriberError.timeout)
                }
            }
        }
    }

    private func run(_ buffers: [AVAudioPCMBuffer]) async throws -> String {
        let module = makeModule()
        let segs = Segments()
        let results = Task { for try await r in module.results { segs.add(r.range, String(r.text.characters)) } }
        let analyzer = SpeechAnalyzer(modules: [module], options: options)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        for b in buffers { cont.yield(AnalyzerInput(buffer: b)) }
        cont.finish()
        do {
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await results.value
        } catch {
            results.cancel()  // 失敗したときに結果待ちの Task を残さない
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return segs.text()
    }

    private func convert(_ samples: [Float], to fmt: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(samples.count)
        guard let src = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: n) else { throw TranscriberError.convert }
        src.frameLength = n
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if fmt == inputFormat { return src }
        return try AudioConvert.convert(src, to: fmt)
    }
}

/// AVAudioConverter でバッファを別のフォーマット (サンプルレート・型) に変換する
enum AudioConvert {
    static func convert(_ src: AVAudioPCMBuffer, to fmt: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let conv = AVAudioConverter(from: src.format, to: fmt) else { throw TranscriberError.convert }
        let cap = AVAudioFrameCount(Double(src.frameLength) * fmt.sampleRate / src.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw TranscriberError.convert }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .endOfStream; return nil }
            fed = true
            inStatus.pointee = .haveData
            return src
        }
        if status == .error || err != nil { throw err ?? TranscriberError.convert }
        return out
    }

    /// 任意のフォーマットのバッファ (1ch 目) を 16kHz mono Float に。
    /// (AVAudioConverter は 3ch 以上から mono へ変換すると無音になるので、チャンネルは自分で取り出す)
    static func toMono16k(_ buf: AVAudioPCMBuffer) throws -> [Float] {
        let fmt16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Transcriber.sampleRate,
                                  channels: 1, interleaved: false)!
        var b = buf
        if b.format.commonFormat != .pcmFormatFloat32 || b.format.isInterleaved {
            let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate,
                                  channels: b.format.channelCount, interleaved: false)!
            b = try convert(b, to: f)  // 型だけそろえる (チャンネル数は変えない)
        }
        var mono = b
        if b.format.channelCount != 1 {
            let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate,
                                  channels: 1, interleaved: false)!
            guard let m = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength) else { throw TranscriberError.convert }
            m.frameLength = b.frameLength
            m.floatChannelData![0].update(from: b.floatChannelData![0], count: Int(b.frameLength))
            mono = m
        }
        let out = mono.format.sampleRate == Transcriber.sampleRate ? mono : try convert(mono, to: fmt16)
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
