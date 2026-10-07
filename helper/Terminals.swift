// AppleScript access to iTerm2 and Terminal.app: which terminal (tty) is in the front tab, and
// putting a transcript into a given one. Each app's script compiles on first use, so a terminal
// that isn't installed never breaks the other. Text always travels as a parameter.

import AppKit

enum TerminalError: Error, CustomStringConvertible {
    case unavailable(String), sessionGone

    var description: String {
        switch self {
        case .unavailable(let what): return "\(what) is not scriptable"
        case .sessionGone: return "that terminal tab was closed"
        }
    }
}

final class Terminals {
    static let pasteSettle = 0.15  // let a paste land before pressing Return
    static let clipboardRestore = 0.5

    private var compiled: [String: ScriptHandlers] = [:]

    private static let sources: [String: String] = [
        TerminalApp.iTerm2.rawValue: """
            on front_tty()
              tell application id "com.googlecode.iterm2" to return tty of current session of current window
            end front_tty

            on write_to(ttyName, t)
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with tb in tabs of w
                    repeat with s in sessions of tb
                      if tty of s is ("/dev/" & ttyName) then
                        tell s to write text t newline NO
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "missing"
            end write_to
            """,
        TerminalApp.terminal.rawValue: """
            on front_tty()
              tell application id "com.apple.Terminal" to return tty of selected tab of front window
            end front_tty
            """,
        "keys": """
            on paste_keys()
              tell application "System Events" to keystroke "v" using command down
            end paste_keys

            on return_key()
              tell application "System Events" to key code 36
            end return_key
            """,
    ]

    private func script(_ name: String) throws -> ScriptHandlers {
        if let s = compiled[name] { return s }
        guard let source = Self.sources[name] else { throw TerminalError.unavailable(name) }
        let s = try ScriptHandlers(source: source)
        compiled[name] = s
        return s
    }

    /// The tty of the front tab, e.g. "ttys009"; nil if it can't be read (no window). Throws
    /// AppleScriptError automationRefused when the user refused Automation of that terminal.
    func frontTTY(_ app: TerminalApp) throws -> String? {
        do {
            return ttyName(try script(app.rawValue).call("front_tty").stringValue ?? "")
        } catch let error as AppleScriptError where error.number == automationRefused {
            throw error
        } catch {
            log("could not read the front tab of \(app): \(error)")
            return nil
        }
    }

    /// Types into the iTerm2 session with this tty, or pastes into Terminal.app's front tab
    /// (the caller checked that it is the right one). Then presses Return if `submit`.
    func put(_ text: String, app: TerminalApp, tty: String, submit: Bool) throws {
        switch app {
        case .iTerm2:
            let s = try script(app.rawValue)
            guard try s.call("write_to", [tty, text]).stringValue == "ok" else { throw TerminalError.sessionGone }
            if submit {
                Thread.sleep(forTimeInterval: Self.pasteSettle)
                try s.call("write_to", [tty, "\r"])
            }
        case .terminal:
            let keys = try script("keys")
            let saved = Clipboard.snapshot()
            Clipboard.set(text)
            try keys.call("paste_keys")
            Thread.sleep(forTimeInterval: Self.pasteSettle)
            if submit { try keys.call("return_key") }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardRestore) { Clipboard.restore(saved) }
        }
    }
}

/// Pastes into whatever has the keyboard focus in the front app: the transcript goes on the
/// clipboard, a synthetic ⌘V follows (Accessibility, no Automation grant), and the person's own
/// clipboard comes back once the app has read it.
enum KeyPaste {
    static let vKey: CGKeyCode = 9  // kVK_ANSI_V

    static func paste(_ text: String) {
        let saved = Clipboard.snapshot()
        Clipboard.set(text)
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Terminals.clipboardRestore) { Clipboard.restore(saved) }
    }
}

enum Clipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// The nspasteboard.org markers: clipboard managers (Raycast, Paste, Maccy, ...) don't keep
    /// a history entry for it, so dictations don't pile up there.
    static let transientMarkers = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                                   NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]

    static func set(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in transientMarkers { item.setData(Data(), forType: marker) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func snapshot() -> Snapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    static func restore(_ snapshot: Snapshot) {
        NSPasteboard.general.clearContents()
        let items = snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.writeObjects(items)
    }
}
