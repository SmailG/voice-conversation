// Pure logic of the hotkey helper, unit-tested by tests/helper/GateTests.swift:
// which key triggers, double-tap timing, where a transcript may go, and transcript cleanup.

import Foundation

/// The physical key whose double tap starts voice input (setting file `hotkey`).
enum Hotkey: String, CaseIterable {
    case rightOption = "right-option", rightCommand = "right-command", fn, off

    init(setting: String?) {
        let value = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self = Hotkey(rawValue: value) ?? .rightOption
    }

    /// Virtual keycode (kVK_RightOption, kVK_RightCommand, kVK_Function).
    var keyCode: Int64? {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        case .off: return nil
        }
    }

    /// The bit in CGEventFlags that is set while this key is down. The right-hand keys have
    /// device-dependent bits (NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK), so the left key never matches.
    var downBit: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .fn: return 0x80_0000  // maskSecondaryFn
        case .off: return 0
        }
    }

    /// Modifier flags that mean "another modifier is held" (shift, control, option, command, fn),
    /// minus this key's own.
    var otherModifiers: UInt64 {
        let all: UInt64 = 0x2_0000 | 0x4_0000 | 0x8_0000 | 0x10_0000 | 0x80_0000
        switch self {
        case .rightOption: return all & ~0x8_0000
        case .rightCommand: return all & ~0x10_0000
        case .fn: return all & ~0x80_0000
        case .off: return all
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .fn: return "Fn"
        case .off: return "off"
        }
    }
}

enum TapEvent: Equatable { case none, tap, doubleTap }

/// Two quick presses of the key alone. Each press is shorter than `maxPress`, the second starts
/// within `maxGap` of the first ending, and nothing else is pressed in between, so holding the
/// key for a shortcut (Right Option + 2 = @ on many layouts) never counts.
struct DoubleTapDetector {
    static let maxPress = 0.2
    static let maxGap = 0.35

    private var downAt: Double?
    private var tapEndedAt: Double?

    mutating func keyDown(at t: Double, othersHeld: Bool) {
        if othersHeld { return interrupted() }
        if let end = tapEndedAt, t - end > Self.maxGap { tapEndedAt = nil }
        downAt = t
    }

    mutating func keyUp(at t: Double) -> TapEvent {
        guard let down = downAt else { return .none }
        downAt = nil
        guard t - down < Self.maxPress else {
            tapEndedAt = nil
            return .none
        }
        if tapEndedAt != nil {
            tapEndedAt = nil
            return .doubleTap
        }
        tapEndedAt = t
        return .tap
    }

    /// Any other key or modifier: whatever was in progress is not a tap.
    mutating func interrupted() {
        downAt = nil
        tapEndedAt = nil
    }
}

enum TerminalApp: String, CaseIterable {
    case iTerm2 = "com.googlecode.iterm2", terminal = "com.apple.Terminal"

    var label: String { self == .iTerm2 ? "iTerm2" : "Terminal" }
}

/// AppleScript's "not authorized to send Apple events" (errAEEventNotPermitted): an Automation
/// permission was refused in System Settings.
let automationRefused = -1743

/// The on-screen message for a permission the helper lacks.
func permissionMessage(_ what: String, _ why: String) -> String {
    "Allow Voice Conversation Hotkey \(what) to \(why): System Settings › Privacy & Security"
}

/// "/dev/ttys009" -> "ttys009"; nil for anything that isn't a terminal name.
func ttyName(_ path: String) -> String? {
    let name = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
    return name.range(of: "^tty[a-z]*[0-9]+$", options: .regularExpression) != nil ? name : nil
}

enum Delivery: Equatable { case type, clipboard }

/// What is true at the moment the transcript is ready.
struct DeliveryState {
    var sessions: [String]       // ttys still running Claude Code
    var guarded: [String]        // ttys showing a menu
    var frontApp: TerminalApp?   // the active app, if it's a supported terminal
    var frontTTY: String?        // Terminal.app's front tab
}

/// Where a finished transcript goes. Typed only into a tab that still runs Claude Code and shows
/// no menu (a permission prompt or question, where "yes" or "2" would answer it). iTerm2 types
/// into the session by its tty. Terminal.app can only paste with keystrokes, which go to the
/// active app, so it must still be active with the same tab in front. Otherwise: the clipboard.
func delivery(app: TerminalApp, tty: String, now: DeliveryState) -> Delivery {
    if !now.sessions.contains(tty) || now.guarded.contains(tty) { return .clipboard }
    if app == .terminal && (now.frontApp != .terminal || now.frontTTY != tty) { return .clipboard }
    return .type
}

// Apps other than iTerm2 and Terminal.app (IDEs, Ghostty, Warp, ...): no tab is addressable, so
// the transcript is pasted where the keyboard focus is. Three guards keep that safe: the app must
// run Claude Code, it must still be the front app at delivery, and no session in it may show a menu.

/// A Claude Code session inside the front app, as the speech service's /host reports it.
struct HostSession: Equatable {
    let tty: String
    let guarded: Bool  // it shows a permission prompt, question or form
}

struct HostState: Equatable {
    let sessions: [HostSession]
    let voiceInput: Bool  // Whisper is installed
}

/// GET /host's JSON; nil when it isn't an answer at all.
func parseHost(_ data: Data) -> HostState? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = json["sessions"] as? [[String: Any]] else { return nil }
    let sessions = list.compactMap { entry -> HostSession? in
        guard let tty = entry["tty"] as? String else { return nil }
        return HostSession(tty: tty, guarded: entry["guarded"] as? Bool ?? false)
    }
    return HostState(sessions: sessions, voiceInput: json["voice_input"] as? Bool ?? false)
}

/// A double-tap in such an app records only while Claude Code runs in it (nil: no answer).
func armsInApp(_ sessions: [HostSession]?) -> Bool {
    !(sessions ?? []).isEmpty
}

enum ClipboardReason: Equatable {
    case appChanged, serviceSilent, noSession, menuOpen

    var message: String {
        switch self {
        case .appChanged: return "you switched apps"
        case .serviceSilent: return "the speech service didn't answer"
        case .noSession: return "Claude Code no longer runs there"
        case .menuOpen: return "Claude is waiting for an answer"
        }
    }
}

enum PasteDecision: Equatable { case paste, clipboard(ClipboardReason) }

/// At delivery: paste into the app the recording started in, if it is still in front, still runs
/// Claude Code, and none of its sessions shows a menu that the pasted text would answer.
func pasteDecision(armedPid: pid_t, frontPid: pid_t?, sessions: [HostSession]?) -> PasteDecision {
    guard frontPid == armedPid else { return .clipboard(.appChanged) }
    guard let sessions else { return .clipboard(.serviceSilent) }
    guard !sessions.isEmpty else { return .clipboard(.noSession) }
    guard !sessions.contains(where: { $0.guarded }) else { return .clipboard(.menuOpen) }
    return .paste
}

/// Make a transcript safe to type into Claude Code: control and format characters (newlines that
/// would submit, escape sequences) and any Unicode space become plain spaces, and a leading "/",
/// "!", "#" or "?" (a command, shell mode, memory, help) is dropped.
func sanitizeTranscript(_ text: String) -> String {
    let blank = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
    let scalars = text.unicodeScalars.map { blank.contains($0) ? " " : Character($0) }
    var clean = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    while let first = clean.first, "/!#?".contains(first) {
        clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return clean
}
