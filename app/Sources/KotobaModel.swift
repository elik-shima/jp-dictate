// kotoba-whisper のモデルファイル (約 1.5GB) の置き場所とダウンロード。アプリ本体には入れない。
import Foundation

enum KotobaModel {
    static let url = URL(string: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0.bin")!
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JPDictate/models")
    static let file = dir.appendingPathComponent("ggml-kotoba-whisper-v2.0.bin")
    /// 完全にダウンロードできたとみなす最小のサイズ (実際は約 1.52GB)
    static let minBytes: Int64 = 1_000_000_000

    static func size(of u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
    static var isInstalled: Bool { size(of: file) > minBytes }

    enum DownloadError: LocalizedError {
        case http(Int), tooSmall(Int64)
        var errorDescription: String? {
            switch self {
            case .http(let c): return "モデルをダウンロードできません (HTTP \(c))"
            case .tooSmall(let n): return "ダウンロードしたモデルが小さすぎます (\(n / 1_000_000)MB)。もう一度試してください"
            }
        }
    }

    /// モデルをダウンロードして所定の場所に置く。途中の内容は .part に書き、完了して大きさを確かめてから移す。
    /// progress は (受け取ったバイト数, 全体のバイト数 (不明なら 0)) を、別スレッドから呼ぶ。
    static func download(to dest: URL = file, from src: URL = url, minBytes: Int64 = minBytes,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        let job = Downloader(part: part, progress: progress)
        try await job.run(src)
        let n = size(of: part)
        guard n > minBytes else { try? fm.removeItem(at: part); throw DownloadError.tooSmall(n) }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }
}

/// URLSession のダウンロード 1 回分 (完了まで await できるようにしたもの)
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let part: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var cont: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var session: URLSession?

    init(part: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.part = part
        self.progress = progress
    }

    func run(_ src: URL) async throws {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        defer { s.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                cont = c
                s.downloadTask(with: src).resume()
            }
        } onCancel: { s.invalidateAndCancel() }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten n: Int64, totalBytesExpectedToWrite total: Int64) {
        progress(n, max(total, 0))
    }

    /// 一時ファイルはこの関数を抜けると消されるので、ここで .part に移す
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
            failure = KotobaModel.DownloadError.http(code)
            return
        }
        do { try FileManager.default.moveItem(at: tmp, to: part) } catch { failure = error }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cont?.resume(with: (error ?? failure).map { .failure($0) } ?? .success(()))
        cont = nil
    }
}
