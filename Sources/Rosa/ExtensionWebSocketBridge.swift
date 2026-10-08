import Foundation
import WebKit

/// WebSockets for extension background workers. Opening one inside a WebKit extension's service
/// worker freezes the worker (1Password's sign-in stalls on it), so the compatibility shim swaps in
/// a stand-in that connects here over a native-messaging port (`runtime.connectNative`) and Rosa
/// runs the real socket with `URLSessionWebSocketTask`.
///
/// Port protocol, JSON-ish dictionaries both ways:
/// - worker → Rosa: `{type: "connect", url, protocols}`, `{type: "send", data, binary}`, `{type: "close", code, reason}`
/// - Rosa → worker: `{type: "ready"}` (then the worker connects), `{type: "open", protocol}`, `{type: "message", data, binary}`, `{type: "error"}`, `{type: "close", code, reason, clean}`
///
/// Binary frames travel as base64.
@MainActor
final class ExtensionWebSocketBridge: NSObject, URLSessionWebSocketDelegate {
    static let applicationID = "rosa.websocket"

    private let port: WKWebExtension.MessagePort
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closed = false
    /// Alive while their port is.
    private static var open: Set<ExtensionWebSocketBridge> = []

    static func accept(_ port: WKWebExtension.MessagePort) {
        let bridge = ExtensionWebSocketBridge(port: port)
        open.insert(bridge)
        // Messages sent before WebKit finishes connecting the port are dropped, both ways: the
        // worker waits for this before it sends "connect".
        Task { @MainActor in bridge.send(["type": "ready"]) }
    }

    private init(port: WKWebExtension.MessagePort) {
        self.port = port
        super.init()
        port.messageHandler = { [weak self] message, _ in
            MainActor.assumeIsolated { self?.handle(message as? [String: Any] ?? [:]) }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "connect":
            guard task == nil, let string = message["url"] as? String, let url = URL(string: string),
                  ["ws", "wss"].contains(url.scheme?.lowercased()) else {
                send(["type": "error"])
                return send(["type": "close", "code": 1006, "reason": "", "clean": false])
            }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
            let protocols = message["protocols"] as? [String] ?? []
            let task = protocols.isEmpty ? session.webSocketTask(with: url) : session.webSocketTask(with: url, protocols: protocols)
            self.session = session
            self.task = task
            task.resume()
            receive()
        case "send":
            guard let task, let data = message["data"] as? String else { return }
            let frame: URLSessionWebSocketTask.Message
            if message["binary"] as? Bool == true, let bytes = Data(base64Encoded: data) {
                frame = .data(bytes)
            } else {
                frame = .string(data)
            }
            task.send(frame) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.failed() }
            }
        case "close":
            let code = (message["code"] as? Int).flatMap(URLSessionWebSocketTask.CloseCode.init(rawValue:)) ?? .normalClosure
            let reason = (message["reason"] as? String).flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            task?.cancel(with: code, reason: reason)
        default:
            break
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .success(.string(let text)):
                    self.send(["type": "message", "data": text, "binary": false])
                    self.receive()
                case .success(.data(let data)):
                    self.send(["type": "message", "data": data.base64EncodedString(), "binary": true])
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.failed()
                }
            }
        }
    }

    private func failed() {
        guard !closed else { return }
        send(["type": "error"])
        let code = task?.closeCode ?? .invalid
        send(["type": "close", "code": code == .invalid ? 1006 : code.rawValue, "reason": "", "clean": false])
        finish()
    }

    private func send(_ message: [String: Any]) {
        guard !port.isDisconnected else { return }
        port.sendMessage(message, completionHandler: nil)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        session?.invalidateAndCancel()
        if !port.isDisconnected { port.disconnect() }
        Self.open.remove(self)
    }

    // MARK: - URLSessionWebSocketDelegate (delegate queue is main)

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated { send(["type": "open", "protocol": `protocol` ?? ""]) }
    }

    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        MainActor.assumeIsolated {
            let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            send(["type": "close", "code": closeCode.rawValue, "reason": text, "clean": true])
            finish()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error != nil else { return }
        MainActor.assumeIsolated { failed() }
    }
}
