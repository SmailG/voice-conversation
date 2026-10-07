// Unit tests for the hotkey helper's pure logic. Run: bash tests/helper/run.sh (macOS).

import Foundation

var passed = 0
var failed = 0

func check<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
    if expected == actual {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name) (expected \(expected), got \(actual))")
    }
}

/// Feeds (down at, up at) presses and returns what each key-up reported.
func taps(_ presses: [(Double, Double)], othersHeld: Bool = false) -> [TapEvent] {
    var d = DoubleTapDetector()
    return presses.map { press in
        d.keyDown(at: press.0, othersHeld: othersHeld)
        return d.keyUp(at: press.1)
    }
}

func detectorTests() {
    check("quick double tap fires", [.tap, .doubleTap], taps([(0, 0.08), (0.25, 0.33)]))
    check("a third tap starts over", [.tap, .doubleTap, .tap], taps([(0, 0.08), (0.25, 0.33), (0.5, 0.58)]))
    check("held first press is no tap", [TapEvent.none, .tap], taps([(0, 0.3), (0.4, 0.45)]))
    check("held second press is no double", [.tap, TapEvent.none], taps([(0, 0.08), (0.2, 0.5)]))
    check("too slow apart is two taps", [.tap, .tap], taps([(0, 0.08), (0.5, 0.58)]))
    check("with another modifier held: nothing", [TapEvent.none, .none], taps([(0, 0.08), (0.2, 0.28)], othersHeld: true))

    var d = DoubleTapDetector()
    d.keyDown(at: 0, othersHeld: false)
    check("first tap", TapEvent.tap, d.keyUp(at: 0.08))
    d.interrupted()  // e.g. Right Option + 2 typed "@" in between
    d.keyDown(at: 0.2, othersHeld: false)
    check("a key in between breaks the double tap", TapEvent.tap, d.keyUp(at: 0.28))

    var held = DoubleTapDetector()
    held.keyDown(at: 0, othersHeld: false)
    held.interrupted()  // a key pressed while Right Option is held
    check("shortcut use is no tap", TapEvent.none, held.keyUp(at: 0.1))
}

func hotkeyTests() {
    check("default is right option", Hotkey.rightOption, Hotkey(setting: nil))
    check("garbage falls back", Hotkey.rightOption, Hotkey(setting: "left-shift; rm"))
    check("reads a setting with newline", Hotkey.fn, Hotkey(setting: "fn\n"))
    check("right option keycode", Int64(61), Hotkey.rightOption.keyCode!)
    check("left option bit is not right option", false, (0x20 as UInt64) & Hotkey.rightOption.downBit != 0)
    check("own modifier is not 'other'", 0, Hotkey.rightOption.otherModifiers & 0x8_0000)
    check("command counts as other for option", true, Hotkey.rightOption.otherModifiers & 0x10_0000 != 0)
}

func deliveryTests() {
    check("tty from device path", "ttys009", ttyName("/dev/ttys009\n"))
    check("permission message names the setting", "Allow Voice Conversation Hotkey the Microphone to hear you: System Settings › Privacy & Security",
          permissionMessage("the Microphone", "hear you"))
    check("non-tty rejected", nil, ttyName("/dev/null"))
    let ok = DeliveryState(sessions: ["ttys009", "ttys010"], guarded: [], frontApp: .terminal, frontTTY: "ttys009")
    func with(_ change: (inout DeliveryState) -> Void) -> DeliveryState {
        var s = ok
        change(&s)
        return s
    }
    check("iTerm2 types even after switching apps and tabs", Delivery.type,
          delivery(app: .iTerm2, tty: "ttys009", now: with { $0.frontApp = nil; $0.frontTTY = "ttys010" }))
    check("guarded session gets clipboard", Delivery.clipboard,
          delivery(app: .iTerm2, tty: "ttys009", now: with { $0.guarded = ["ttys009"] }))
    check("other session guarded: still types", Delivery.type,
          delivery(app: .iTerm2, tty: "ttys009", now: with { $0.guarded = ["ttys010"] }))
    check("Claude Code exited meanwhile: clipboard", Delivery.clipboard,
          delivery(app: .iTerm2, tty: "ttys009", now: with { $0.sessions = ["ttys010"] }))
    check("Terminal active, same tab: types", Delivery.type, delivery(app: .terminal, tty: "ttys009", now: ok))
    check("Terminal tab switched: clipboard", Delivery.clipboard,
          delivery(app: .terminal, tty: "ttys009", now: with { $0.frontTTY = "ttys010" }))
    check("Terminal no longer the active app: clipboard", Delivery.clipboard,
          delivery(app: .terminal, tty: "ttys009", now: with { $0.frontApp = nil }))
}

func hostTests() {
    let json = #"{"pid": 500, "voice_input": true, "sessions": [{"tty": "ttys010", "guarded": false}, {"tty": "ttys011", "guarded": true}]}"#
    let host = parseHost(Data(json.utf8))
    check("host parsed", HostState(sessions: [HostSession(tty: "ttys010", guarded: false),
                                              HostSession(tty: "ttys011", guarded: true)], voiceInput: true), host)
    check("host without sessions parses as empty", HostState(sessions: [], voiceInput: false),
          parseHost(Data(#"{"pid": 9, "sessions": []}"#.utf8)))
    check("garbage is no answer", nil, parseHost(Data("not json".utf8)))
    check("a session without a tty is dropped", HostState(sessions: [], voiceInput: false),
          parseHost(Data(#"{"sessions": [{"guarded": true}]}"#.utf8)))

    let one = [HostSession(tty: "ttys010", guarded: false)]
    check("arms in an app running Claude Code", true, armsInApp(one))
    check("no session in the app: does not arm", false, armsInApp([]))
    check("service did not answer: does not arm", false, armsInApp(nil))

    check("same app, session idle: pastes", PasteDecision.paste, pasteDecision(armedPid: 500, frontPid: 500, sessions: one))
    check("app changed while transcribing: clipboard", PasteDecision.clipboard(.appChanged),
          pasteDecision(armedPid: 500, frontPid: 600, sessions: one))
    check("no front app: clipboard", PasteDecision.clipboard(.appChanged),
          pasteDecision(armedPid: 500, frontPid: nil, sessions: one))
    check("Claude Code exited meanwhile: clipboard", PasteDecision.clipboard(.noSession),
          pasteDecision(armedPid: 500, frontPid: 500, sessions: []))
    check("service silent at delivery: clipboard", PasteDecision.clipboard(.serviceSilent),
          pasteDecision(armedPid: 500, frontPid: 500, sessions: nil))
    check("a session in the app shows a menu: clipboard", PasteDecision.clipboard(.menuOpen),
          pasteDecision(armedPid: 500, frontPid: 500,
                        sessions: one + [HostSession(tty: "ttys011", guarded: true)]))
}

func keyLayoutTests() {
    check("no key types an emoji", nil, keyCode(typing: "\u{1F600}"))
    // A runner without layout data has no answer for "v"; where there is one, it is a real key code.
    if let v = keyCode(typing: "v") {
        check("the key for v is a key code", true, v < 128)
        check("v and b are different keys", true, keyCode(typing: "b").map { $0 != v } ?? true)
    }
    check("empty layout data finds nothing", nil, keyCode(typing: "v", layoutData: Data()))
}

func sanitizeTests() {
    check("newlines become spaces", "fix the bug and run tests", sanitizeTranscript("fix the bug\nand run\r\ntests\n"))
    check("escape sequences neutralised", "[31m red", sanitizeTranscript("\u{1B}[31m red"))
    check("leading command chars dropped", "clear everything", sanitizeTranscript(" / ! clear everything"))
    check("inner slash kept", "use a/b", sanitizeTranscript("use a/b"))
    check("Bosnian letters kept", "Šta je ovo, čemu služi?", sanitizeTranscript("Šta je ovo, čemu služi?"))
    check("only noise is empty", "", sanitizeTranscript(" \n#\t"))
    check("unicode spaces can't hide a slash", "compact", sanitizeTranscript("\u{00A0}\u{3000}/compact"))
    check("bidi override removed", "a b", sanitizeTranscript("a\u{202E}b"))
}

func wavTests() {
    let wav = wavData(samples: [0, 1, -1, 2], sampleRate: 48000)
    check("header + 2 bytes per sample", 44 + 8, wav.count)
    check("RIFF tag", "RIFF", String(decoding: wav.prefix(4), as: UTF8.self))
    let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    check("sample rate", UInt32(48000), UInt32(littleEndian: rate))
    let clipped = wav.subdata(in: 50..<52).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
    check("out-of-range sample is clipped", Int16(32767), Int16(littleEndian: clipped))
}

func appleScriptTests() {
    let marker = NSTemporaryDirectory() + "voice-conversation-injection-\(getpid())"
    let hostile = "\" & (do shell script \"touch \(marker)\") & \"\nend run"
    do {
        let script = try ScriptHandlers(source: "on echo_text(t)\nreturn t\nend echo_text")
        check("hostile text comes back verbatim", hostile, try script.call("echo_text", [hostile]).stringValue ?? "")
        check("hostile text ran nothing", false, FileManager.default.fileExists(atPath: marker))
        check("unicode survives", "čćžšđ — ok", try script.call("echo_text", ["čćžšđ — ok"]).stringValue ?? "")
    } catch {
        check("AppleScript call works", "ok", "\(error)")
    }
}

@main
struct GateTests {
    static func main() {
        detectorTests()
        hotkeyTests()
        deliveryTests()
        hostTests()
        keyLayoutTests()
        sanitizeTests()
        wavTests()
        appleScriptTests()
        print("helper tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 && passed > 0 ? 0 : 1)
    }
}
