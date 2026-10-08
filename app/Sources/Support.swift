// ログと macOS の状態の取得
import AppKit
import Carbon
import Foundation

enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/JPDictate")
    static let url = dir.appendingPathComponent("dictate.log")
    /// JPD_LOG_TEXT=1 のときだけ認識した文章をログに書く
    static let logText = ProcessInfo.processInfo.environment["JPD_LOG_TEXT"] == "1"
    /// true のときはファイルではなく標準エラーに書く (CLI モード)
    nonisolated(unsafe) static var toStderr = false
    private static let queue = DispatchQueue(label: "jp-dictate.log")
    nonisolated(unsafe) private static var handle: FileHandle?

    static func open() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 2MB を超えたら 1 世代だけ残して新しくする
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = dir.appendingPathComponent("dictate.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
    }

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
        queue.async {
            let data = Data("\(stamp) \(line)\n".utf8)
            if toStderr { FileHandle.standardError.write(data); return }
            guard let h = handle else { return }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)  // 書けなくても (ディスク満杯など) 落ちない
        }
    }
}

enum SystemState {
    /// パスワード欄などでセキュア入力が有効か。その間は貼り付けない。
    static var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    static var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// キーボード・マウスを最後に操作してからの秒数
    static var userIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// fn (🌐) キーに絵文字パネル等が割り当てられていると、押すたびにそれも開いてしまう
    static var globeKeyDoesNothing: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) == 0
    }
}
