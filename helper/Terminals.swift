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
            let giveBack = Clipboard.lend(text)
            defer { giveBack() }
            try keys.call("paste_keys")
            Thread.sleep(forTimeInterval: Self.pasteSettle)
            if submit { try keys.call("return_key") }
        }
    }
}

/// Pastes into whatever has the keyboard focus in the front app: the transcript goes on the
/// clipboard, a synthetic ⌘V follows (Accessibility, no Automation grant), and the person's own
/// clipboard comes back once the app has read it.
enum KeyPaste {
    static let ansiV: CGKeyCode = 9  // kVK_ANSI_V: where "v" is on a US layout

    static func paste(_ text: String) {
        let giveBack = Clipboard.lend(text)
        defer { giveBack() }
        let vKey = keyCode(typing: "v") ?? ansiV
        // A private source: the ⌘ on these events must not leak into the session's modifier state,
        // where the next synthetic key (or the person's) would read as ⌘-something.
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

enum Clipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// The nspasteboard.org markers: clipboard managers (Raycast, Paste, Maccy, ...) don't keep
    /// a history entry for it, so dictations don't pile up there.
    static let transientMarkers = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                                   NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]

    /// `transient`: for the moment of a paste only, so clipboard managers skip it. A copy the
    /// person pastes by hand is a normal one: if it goes nowhere, their history still has it.
    static func set(_ text: String, transient: Bool = false) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            for marker in transientMarkers { item.setData(Data(), forType: marker) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Puts `text` on the clipboard for one paste and returns the call that gives the person's
    /// clipboard back after `Terminals.clipboardRestore`, unless something was copied meanwhile.
    static func lend(_ text: String) -> () -> Void {
        let saved = snapshot()
        set(text, transient: true)
        let lent = NSPasteboard.general.changeCount
        return {
            DispatchQueue.main.asyncAfter(deadline: .now() + Terminals.clipboardRestore) {
                if NSPasteboard.general.changeCount == lent { restore(saved) }
            }
        }
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
