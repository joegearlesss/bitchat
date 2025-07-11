import Foundation
import Network
#if os(iOS)
import UIKit
#endif

protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceiveMessage(_ data: Data)
}

class WebSocketService: NSObject, ObservableObject {
    weak var delegate: WebSocketServiceDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var heartbeatTimer: Timer?
    
    @Published var connectionState: ConnectionState = .disconnected
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    func connect(to url: URL, with auth: BridgeAuth) {
        guard !isConnected else { return }
        
        connectionState = .connecting
        
        var request = URLRequest(url: url)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("bitchat-bridge/1.0", forHTTPHeaderField: "User-Agent")
        
        // Add authentication headers
        request.setValue(auth.networkId, forHTTPHeaderField: "X-Network-ID")
        request.setValue(auth.publicKey, forHTTPHeaderField: "X-Public-Key")
        request.setValue(auth.signature, forHTTPHeaderField: "X-Signature")
        request.setValue("\(auth.timestamp)", forHTTPHeaderField: "X-Timestamp")
        
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        startReceiving()
        startHeartbeat()
    }
    
    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        connectionState = .disconnected
    }
    
    func send(_ data: Data) {
        guard isConnected else { return }
        
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                print("WebSocket send error: \(error)")
                DispatchQueue.main.async {
                    self?.connectionState = .error(error.localizedDescription)
                }
            }
        }
    }
    
    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.delegate?.webSocketDidReceiveMessage(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self?.delegate?.webSocketDidReceiveMessage(data)
                    }
                @unknown default:
                    break
                }
                self?.startReceiving() // Continue receiving
                
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                DispatchQueue.main.async {
                    self?.connectionState = .error(error.localizedDescription)
                }
                self?.delegate?.webSocketDidDisconnect(error: error)
            }
        }
    }
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard self?.isConnected == true else { return }
            
            let heartbeat = BridgeMessage(
                id: UUID().uuidString,
                type: .heartbeat,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                ttl: 1,
                payload: Data(),
                sourceNetwork: self?.getCurrentNetworkId() ?? ""
            )
            
            if let data = try? heartbeat.serialize() {
                self?.send(data)
            }
        }
    }
    
    private func getCurrentNetworkId() -> String {
        #if os(iOS)
        return "network-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown")"
        #else
        return "network-\(ProcessInfo.processInfo.globallyUniqueString.prefix(8))"
        #endif
    }
}

extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isConnected = true
        DispatchQueue.main.async {
            self.connectionState = .connected
        }
        delegate?.webSocketDidConnect()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
        delegate?.webSocketDidDisconnect(error: nil)
    }
}