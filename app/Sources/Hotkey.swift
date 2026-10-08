// 録音キーの監視 (Quartz のイベントタップ、listen-only)。
// 押下/解放は FlagsChanged のキーコードと修飾フラグで判定する。右側の修飾キーは左右を区別する
// デバイス依存フラグ (NX_DEVICER*KEYMASK) で見るので、左側を押したままでも正しく判定できる。
// それ以外のキー・修飾キーは「他のキー」として通知する (録音中ならキャンセルに使う)。
// Shift だけは例外: 録音キーと一緒に押すと清書モードになるので、Shift の上げ下げではキャンセルしない。
import CoreGraphics
import Foundation

/// 録音に使うキー。Apple 製以外のキーボードでは fn がキーボード内部で処理されて Mac に届かないことが多いので、
/// 右側の修飾キーも選べるようにする。
enum TriggerKey: String, CaseIterable {
    case fn, rightOption, rightCommand, rightControl

    var label: String {
        switch self {
        case .fn: return "fn (🌐)"
        case .rightOption: return "右 ⌥ (option)"
        case .rightCommand: return "右 ⌘ (command)"
        case .rightControl: return "右 ⌃ (control)"
        }
    }
    var shortLabel: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "右⌥"
        case .rightCommand: return "右⌘"
        case .rightControl: return "右⌃"
        }
    }
    fileprivate var keycode: Int64 {
        switch self {
        case .fn: return 63            // kVK_Function (地球儀キーも同じ)
        case .rightOption: return 61   // kVK_RightOption
        case .rightCommand: return 54  // kVK_RightCommand
        case .rightControl: return 62  // kVK_RightControl
        }
    }
    fileprivate func isDown(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.rawValue & 0x40 != 0     // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags.rawValue & 0x10 != 0    // NX_DEVICERCMDKEYMASK
        case .rightControl: return flags.rawValue & 0x2000 != 0  // NX_DEVICERCTLKEYMASK
        }
    }

    static var saved: TriggerKey {
        get { TriggerKey(rawValue: UserDefaults.standard.string(forKey: "triggerKey") ?? "") ?? .fn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "triggerKey") }
    }
}

final class HotkeyMonitor {
    /// 引数は、録音キーを押した時点で Shift が押されていたか (清書モード)
    var onDown: (Bool) -> Void = { _ in }
    var onUp: () -> Void = {}
    var onOther: () -> Void = {}
    var key: TriggerKey = .saved
    private var tap: CFMachPort?
    private let me = Int64(getpid())

    /// 入力監視の許可がないと nil が返るか、作れても何も届かない (起動時に許可を確認すること)
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: ctx) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // 自分が送った ⌘V (⌘ の FlagsChanged も含む) は無視する
        if event.getIntegerValueField(.eventSourceUnixProcessID) == me { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged && code == key.keycode {
            key.isDown(event.flags) ? onDown(event.flags.contains(.maskShift)) : onUp()
        } else if type == .flagsChanged && (code == 56 || code == 60) {
            return  // 左右の Shift (kVK_Shift / kVK_RightShift)
        } else {
            onOther()
        }
    }
}
