// The macOS privacy permissions the helper needs, and a status file that /speak status reads.
//   Input Monitoring  see the double tap (a listen-only event tap; keys are never consumed or logged)
//   Microphone        record what you say
//   Automation        ask iTerm2 / Terminal which tab is in front and type into it
//   Accessibility     every app but iTerm2: paste with Cmd+V (Terminal.app also presses Return)

import AVFoundation
import AppKit
import CoreServices

enum Permissions {
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static var microphone: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        default: return "not asked"
        }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone(then done: @escaping @Sendable () -> Void = {}) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log("microphone \(granted ? "granted" : "denied")")
            DispatchQueue.main.async(execute: done)
        }
    }

    static func askAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Asks for Automation of each running supported terminal now, while setup has the user's
    /// attention, instead of at the first double tap. Blocks while a prompt is open, so off main.
    static func primeAutomation() {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        let wildcard: FourCharCode = 0x2A2A_2A2A  // typeWildCard '****'
        DispatchQueue.global(qos: .utility).async {
            for app in [TerminalApp.iTerm2, .terminal] where running.contains(app.rawValue) {
                let target = NSAppleEventDescriptor(bundleIdentifier: app.rawValue)
                guard let desc = target.aeDesc else { continue }
                let status = AEDeterminePermissionToAutomateTarget(desc, wildcard, wildcard, true)
                log("automation of \(app): \(status == noErr ? "granted" : "status \(status)")")
            }
        }
    }

    /// Running terminals whose Automation permission was refused (asked without prompting).
    static func automationDenied(running: [String]) -> [String] {
        let wildcard: FourCharCode = 0x2A2A_2A2A
        return TerminalApp.allCases.filter { running.contains($0.rawValue) }.compactMap { app in
            guard let desc = NSAppleEventDescriptor(bundleIdentifier: app.rawValue).aeDesc else { return nil }
            let status = AEDeterminePermissionToAutomateTarget(desc, wildcard, wildcard, false)
            return Int(status) == automationRefused ? app.label : nil
        }
    }

    /// Read by /speak status and the session-start warning (scripts/voice-input-state.sh).
    static func writeStatus(dataDir: String, hotkey: Hotkey) {
        let status: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "hotkey": hotkey.rawValue,
            "input_monitoring": inputMonitoring,
            "microphone": microphone,
            "accessibility": accessibility,
        ]
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        DispatchQueue.global(qos: .utility).async {
            var full = status
            full["automation_denied"] = automationDenied(running: running)
            guard let data = try? JSONSerialization.data(withJSONObject: full, options: [.sortedKeys]) else { return }
            try? data.write(to: URL(fileURLWithPath: dataDir).appendingPathComponent("hotkey_status.json"),
                            options: .atomic)
        }
    }
}
