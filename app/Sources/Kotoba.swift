// kotoba-whisper v2.0 (Whisper large-v3 の日本語蒸留モデル) を whisper.cpp で直接動かす認識エンジン。
// whisper.cpp は静的ライブラリとしてアプリに組み込み済み (別プロセスも HTTP も使わない)。モデルは Metal (GPU) で動かす。
// 昔の Python 版 (whisper-server 経由) で確かめた注意点:
//   ・タイムスタンプ付きで認識する (no_timestamps=true だと最初の文の後の文を黙って落とす)
//   ・初期プロンプトは付けない (句読点入りのプロンプトは誤りが倍になった)
//   ・長い音声は後半を落としやすいので、約 14 秒以下に無音の位置で分けてつなぐ
import Foundation

enum KotobaError: LocalizedError {
    case modelMissing, loadFailed, notPrepared
    case failed(Int32)
    var errorDescription: String? {
        switch self {
        case .modelMissing: return "kotoba-whisper のモデルがありません (\(KotobaModel.file.path))"
        case .loadFailed: return "kotoba-whisper のモデルを読み込めません (ファイルが壊れているか、メモリが足りません)"
        case .notPrepared: return "kotoba-whisper の準備ができていません"
        case .failed(let c): return "kotoba-whisper の認識に失敗しました (コード \(c))"
        }
    }
}

final class KotobaEngine: SpeechEngine, @unchecked Sendable {
    static let sampleRate = 16_000
    static let chunkSeconds = 14.0   // これより長い音声は分ける
    static let minChunkSeconds = 6.0 // 分けたときの 1 区間の最小の長さ

    let kind = EngineKind.kotoba
    /// whisper の呼び出しはすべてこの 1 本のキューで順番に行う (whisper_context は同時に使えない)
    private let queue = DispatchQueue(label: "jp-dictate.kotoba", qos: .userInitiated)
    private var ctx: OpaquePointer?  // queue の中でだけ触る
    private let threads: Int32 = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // 高性能コアの数 (Apple Silicon)。取れなければ全コアの半分
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) != 0 || n <= 0 {
            n = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        }
        return n
    }()

    deinit { release() }

    // MARK: - SpeechEngine

    func prepare() async throws {
        try await onQueue { try self.load() }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        return try await onQueue {
            guard self.ctx != nil else { throw KotobaError.notPrepared }
            return try Self.splitAtPauses(samples).map { try self.run($0) }.joined()
        }
    }

    func unload() {
        queue.async { self.release() }
    }

    /// 解放が終わるまで待つ。プロセスを終える前に必ず呼ぶ (Metal のデバイスが後始末のときに、解放されていない資源で異常終了するため)
    func unloadAndWait() {
        queue.sync { self.release() }
    }

    private func release() {
        if let c = ctx { whisper_free(c); ctx = nil; Log.write("kotoba-whisper を解放しました") }
    }

    // MARK: - whisper.cpp

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }

    private static let logCallback: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { level, text, _ in
        // 通常は警告とエラーだけ残す (JPD_WHISPER_LOG=1 なら Metal の初期化などの詳細も)
        guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue || ProcessInfo.processInfo.environment["JPD_WHISPER_LOG"] == "1",
              let text else { return }
        Log.write("whisper: " + String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func load() throws {
        if ctx != nil { return }
        guard KotobaModel.isInstalled else { throw KotobaError.modelMissing }
        whisper_log_set(Self.logCallback, nil)
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true
        var c = whisper_init_from_file_with_params(KotobaModel.file.path, cp)
        if c == nil {  // フラッシュアテンションが使えない環境向けに、なしでもう一度
            cp.flash_attn = false
            c = whisper_init_from_file_with_params(KotobaModel.file.path, cp)
        }
        guard let c else { throw KotobaError.loadFailed }
        ctx = c
        // 最初の認識は Metal のシェーダーのコンパイルなどで遅いので、無音に近い音で 1 回空回ししておく
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let noise = (0..<Self.sampleRate / 2).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.002
        }
        _ = try? run(noise)
    }

    /// 1 区間 (約 14 秒以下) を認識して、区間の文を連結して返す (queue の中で呼ぶ)
    private func run(_ chunk: [Float]) throws -> String {
        guard let ctx else { throw KotobaError.notPrepared }
        // whisper-server の既定に合わせる: 貪欲法 (温度 0、認識が怪しいときだけ温度を上げてやり直す)、前の発話を文脈にしない
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = threads
        p.translate = false
        p.no_context = true
        p.no_timestamps = false
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.token_timestamps = false
        p.initial_prompt = nil
        p.detect_language = false
        p.temperature = 0
        p.temperature_inc = 0.2
        p.greedy.best_of = 2
        let rc = "ja".withCString { lang -> Int32 in
            p.language = lang
            return chunk.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
        guard rc == 0 else { throw KotobaError.failed(rc) }
        var out = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let t = whisper_full_get_segment_text(ctx, i) { out += String(cString: t) }
        }
        return out
    }

    // MARK: - 無音の位置での分割

    /// maxSec 以下の長さになるよう、各区間の中でいちばん静かな 0.2 秒の位置で切る (1 区間は minSec 以上)
    static func splitAtPauses(_ audio: [Float], maxSec: Double = chunkSeconds, minSec: Double = minChunkSeconds) -> [[Float]] {
        let sr = Double(sampleRate)
        let maxn = Int(maxSec * sr), minn = Int(minSec * sr), win = Int(0.2 * sr), hop = Int(0.02 * sr)
        var out: [[Float]] = []
        var start = 0
        while audio.count - start > maxn {
            let segStart = start + minn, segLen = maxn - minn
            // 累積二乗和から、各位置の 0.2 秒分のエネルギーをすぐ求められるようにする
            var c = [Double](repeating: 0, count: segLen + 1)
            for i in 0..<segLen { let v = Double(audio[segStart + i]); c[i + 1] = c[i] + v * v }
            var best = 0, bestE = Double.infinity
            for pos in stride(from: 0, to: segLen - win, by: hop) {
                let e = c[pos + win] - c[pos]
                if e < bestE { bestE = e; best = pos }
            }
            let cut = segStart + best + win / 2
            out.append(Array(audio[start..<cut]))
            start = cut
        }
        out.append(Array(audio[start...]))
        return out
    }
}
