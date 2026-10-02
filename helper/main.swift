// Voice Conversation Hotkey: double-tap a key (default Right Option) in an iTerm2 or Terminal.app tab
// that runs Claude Code, speak, tap once more, and the local transcript lands in the prompt.
// Elsewhere the key does nothing. Runs as the LaunchAgent com.voice-conversation.hotkey:
//   VoiceConversationHotkey <plugin data dir>
// Settings (files in the data dir): hotkey = right-option|right-command|fn|off, autosend = on|off.

import AppKit

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
}

struct Target {
    let app: TerminalApp
    let tty: String
}

enum Phase {
    case idle, listening(Target), transcribing
}

final class Controller {
    let dataDir: String
    let hotkey: Hotkey
    let daemon: Daemon
    let terminals = Terminals()
    let hud = HUD()
    let recorder = Recorder()
    var detector = DoubleTapDetector()
    var phase = Phase.idle
    var tap: CFMachPort?

    init(dataDir: String) {
        self.dataDir = dataDir
        hotkey = Hotkey(setting: Self.setting(dataDir, "hotkey"))
        daemon = Daemon(port: Int(ProcessInfo.processInfo.environment["VOICE_CONVERSATION_PORT"] ?? "") ?? 8765)
        recorder.onAutoStop = { [weak self] in self?.finishListening() }
    }

    static func setting(_ dir: String, _ name: String) -> String? {
        try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)
    }

    static let logLimit = 512 * 1024

    func start() {
        trimLog()
        Permissions.writeStatus(dataDir: dataDir, hotkey: hotkey)
        guard hotkey != .off else { return log("hotkey is off; idle") }
        requestMicrophone()
        guard Permissions.inputMonitoring else { return waitForInputMonitoring() }
        guard installTap() else {
            log("could not create the event tap")
            exit(1)
        }
        Permissions.primeAutomation()
        Timer.scheduledTimer(withTimeInterval: Self.statusEvery, repeats: true) { _ in controller.recheck() }
        log("ready: double-tap \(hotkey.label) in a Claude Code tab")
    }

    static let statusEvery = 60.0

    /// Keeps the status file current (a permission can be turned off at any time). Without Input
    /// Monitoring the tap goes deaf, so restart into the waiting state, which asks for it again.
    func recheck() {
        guard Permissions.inputMonitoring else {
            log("Input Monitoring was turned off; restarting to wait for it")
            exit(0)
        }
        Permissions.writeStatus(dataDir: dataDir, hotkey: hotkey)
    }

    /// launchd opens the log O_APPEND, so truncating it in place is safe.
    func trimLog() {
        let path = dataDir + "/hotkey.log"
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > Self.logLimit {
            truncate(path, 0)
        }
    }

    /// The tap can only be created by a process started after the grant, so restart once it's given.
    func waitForInputMonitoring() {
        _ = CGRequestListenEventAccess()
        log("waiting for Input Monitoring permission")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            guard Permissions.inputMonitoring else { return }
            log("Input Monitoring granted; restarting")
            exit(0)
        }
    }

    func requestMicrophone() {
        let dataDir = self.dataDir, hotkey = self.hotkey
        Permissions.requestMicrophone { Permissions.writeStatus(dataDir: dataDir, hotkey: hotkey) }
    }

    func installTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                controller.handle(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: nil) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Only looks at which key changed, never at what was typed.
    func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            detector.interrupted()
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keyCode else {
                return detector.interrupted()
            }
            let flags = event.flags.rawValue, now = ProcessInfo.processInfo.systemUptime
            if flags & hotkey.downBit != 0 {
                detector.keyDown(at: now, othersHeld: flags & hotkey.otherModifiers != 0)
            } else {
                react(to: detector.keyUp(at: now))
            }
        default:
            break
        }
    }

    func react(to tap: TapEvent) {
        switch (phase, tap) {
        case (.idle, .doubleTap): beginListening()
        case (.listening, .tap): finishListening()
        default: break
        }
    }

    func beginListening() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let app = TerminalApp(rawValue: id) else { return }
        let frontTTY: String?
        do {
            frontTTY = try terminals.frontTTY(app)
        } catch {
            Permissions.writeStatus(dataDir: dataDir, hotkey: hotkey)
            return hud.show(permissionMessage("to control \(app.label)", "find the Claude Code tab (Automation)"), for: 6)
        }
        guard let tty = frontTTY else { return }
        guard let tab = daemon.tab(tty) else {
            return hud.show("voice-conversation: the speech service is not running (or still loading)", for: 3)
        }
        guard tab.runsClaude else { return }  // this tab isn't running Claude Code
        guard tab.voiceInput else { return hud.show("Voice input is not set up: run /speak setup input", for: 4) }
        guard Permissions.microphone == "granted" else {
            requestMicrophone()
            Permissions.writeStatus(dataDir: dataDir, hotkey: hotkey)
            return hud.show(permissionMessage("the Microphone", "hear you"), for: 6)
        }
        daemon.prepare()
        do {
            try recorder.start()
        } catch {
            log("microphone error: \(error)")
            return hud.show("Could not start the microphone", for: 3)
        }
        phase = .listening(Target(app: app, tty: tty))
        hud.show("● Listening — tap \(hotkey.label) to stop")
        log("listening in \(app) \(tty)")
    }

    func finishListening() {
        guard case .listening(let target) = phase else { return }
        let (wav, seconds) = recorder.stop()
        guard recorder.heardSpeech else {  // Whisper turns silence into "Thank you."
            phase = .idle
            return hud.show("Didn't hear anything", for: 2)
        }
        phase = .transcribing
        hud.show("Transcribing…")
        let daemon = self.daemon
        DispatchQueue.global(qos: .userInitiated).async {
            let result = daemon.transcribe(wav)
            DispatchQueue.main.async { controller.finish(result, seconds: seconds, target: target) }
        }
    }

    func finish(_ result: Result<String, TranscribeError>, seconds: Double, target: Target) {
        phase = .idle
        switch result {
        case .failure(let error):
            log("transcription failed: \(error.message)")
            hud.show("Transcription failed: \(error.message)", for: 4)
        case .success(let text):
            log(String(format: "transcribed %.1fs -> %d chars", seconds, text.count))
            deliver(sanitizeTranscript(text), to: target)
        }
    }

    func deliver(_ text: String, to target: Target) {
        guard !text.isEmpty else { return hud.show("Didn't catch that", for: 2) }
        let tab = daemon.tab(target.tty)  // no answer: nothing is known to be safe, so the clipboard
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap(TerminalApp.init)
        let now = DeliveryState(sessions: tab?.runsClaude == true ? [target.tty] : [],
                                guarded: tab?.guarded == true ? [target.tty] : [],
                                frontApp: frontApp,
                                frontTTY: frontApp == .terminal ? (try? terminals.frontTTY(.terminal)) ?? nil : nil)
        let how = delivery(app: target.app, tty: target.tty, now: now)
        if how == .type && target.app == .terminal && !Permissions.accessibility {
            Permissions.askAccessibility()
            return copy(text, permissionMessage("Accessibility", "paste into Terminal") + ". Copied: paste with ⌘V")
        }
        if how == .clipboard {
            let why = tab == nil ? "the speech service didn't answer"
                : now.guarded.contains(target.tty) ? "Claude is waiting for an answer"
                : !now.sessions.contains(target.tty) ? "Claude Code no longer runs in that tab"
                : "couldn't type there"
            return copy(text, "Copied (\(why)) — paste with ⌘V")
        }
        do {
            let submit = Self.setting(dataDir, "autosend")?.trimmingCharacters(in: .whitespacesAndNewlines) == "on"
            try terminals.put(text, app: target.app, tty: target.tty, submit: submit)
            hud.hide()
        } catch let error as AppleScriptError where error.number == automationRefused {
            let what = target.app == .terminal ? "to control System Events" : "to control \(target.app.label)"
            copy(text, permissionMessage(what, "type for you (Automation)") + ". Copied: paste with ⌘V")
        } catch {
            log("could not type into \(target.app) \(target.tty): \(error)")
            copy(text, "Copied (couldn't type there) — paste with ⌘V")
        }
    }

    func copy(_ text: String, _ message: String) {
        Clipboard.set(text)
        log("copied to the clipboard: \(message)")
        hud.show(message, for: 6)
    }
}

guard CommandLine.arguments.count == 2 else {
    print("usage: VoiceConversationHotkey <voice-conversation data dir>")
    exit(2)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = Controller(dataDir: CommandLine.arguments[1])
controller.start()
application.run()
