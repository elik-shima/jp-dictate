// 認識エンジンの共通の形と、メニューで選べる種類 (Apple 内蔵 / kotoba-whisper)。
import Foundation

/// 16kHz mono Float の音声を文字にするもの。同時に複数回呼ばれても順番に処理する。
protocol SpeechEngine: AnyObject, Sendable {
    var kind: EngineKind { get }
    /// モデルの用意と読み込み (すでに読み込み済みなら何もしない)
    func prepare() async throws
    func transcribe(_ samples: [Float]) async throws -> String
    /// モデルを手放してメモリを空ける (処理中の認識があれば終わるのを待ってから)
    func unload()
}

enum EngineKind: String, CaseIterable {
    case apple, kotoba

    var label: String {
        switch self {
        case .apple: return "Apple 内蔵 (軽量・句読点あり)"
        case .kotoba: return "kotoba-whisper (高精度・約1.7GB)"
        }
    }
    var shortLabel: String {
        switch self {
        case .apple: return "Apple 内蔵"
        case .kotoba: return "kotoba-whisper"
        }
    }

    private static let key = "engine"
    /// 選んだエンジン (UserDefaults に保存。既定は apple)
    static var saved: EngineKind {
        get { EngineKind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
