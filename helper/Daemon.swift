// HTTP client for the local speech service (speakd). Blocking calls with short timeouts:
// the service is on localhost, and only /transcribe takes long (call that off the main thread).

import Foundation

/// One terminal as the speech service sees it.
struct TabState {
    let runsClaude: Bool  // an interactive Claude Code session runs in it
    let guarded: Bool     // it shows a permission prompt, question or form
    let voiceInput: Bool  // Whisper is installed
}

final class Daemon: @unchecked Sendable {
    static let transcribeTimeout = 130.0
    static let queryTimeout = 3.0  // localhost, but the service may be busy generating speech

    private let base: URL

    init(port: Int) {
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    /// nil when the service can't answer (not running, still loading, or the scan failed).
    func tab(_ tty: String) -> TabState? {
        guard let (code, data) = request("session?tty=\(tty)", timeout: Self.queryTimeout), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let open = json["open"] as? Bool, let guarded = json["guarded"] as? Bool else { return nil }
        return TabState(runsClaude: open, guarded: guarded, voiceInput: json["voice_input"] as? Bool ?? false)
    }

    /// The Claude Code sessions inside the app with this pid; nil when the service can't answer.
    func host(_ pid: pid_t) -> HostState? {
        guard let (code, data) = request("host?pid=\(pid)", timeout: Self.queryTimeout), code == 200 else { return nil }
        return parseHost(data)
    }

    /// Silences speech (empty body = every session) and starts loading Whisper.
    func prepare() {
        _ = request("stop", body: Data())
        _ = request("prepare", body: Data())
    }

    func transcribe(_ wav: Data) -> Result<String, TranscribeError> {
        guard let (code, data) = request("transcribe", body: wav, timeout: Self.transcribeTimeout) else {
            return .failure(TranscribeError(message: "the speech service did not answer"))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200, let text = json?["text"] as? String else {
            return .failure(TranscribeError(message: json?["error"] as? String ?? "HTTP \(code)"))
        }
        return .success(text)
    }

    private func request(_ path: String, body: Data? = nil, timeout: Double = 1) -> (Int, Data)? {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse { box.value = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }
}

struct TranscribeError: Error {
    let message: String
}

private final class ResponseBox: @unchecked Sendable {
    var value: (Int, Data)?
}
