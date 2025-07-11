import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#endif

protocol BridgeClientDelegate: AnyObject {
    func bridgeDidConnect(_ bridge: BridgeClient)
    func bridgeDidDisconnect(_ bridge: BridgeClient, error: Error?)
    func bridgeDidReceiveMessage(_ bridge: BridgeClient, message: BitchatPacket)
}

class BridgeClient: ObservableObject {
    weak var delegate: BridgeClientDelegate?
    private let webSocketService = WebSocketService()
    private let encryptionService: EncryptionService
    private var signingKey: Curve25519.Signing.PrivateKey
    
    @Published var isConnected = false
    @Published var bridgeURL: URL?
    @Published var connectionError: String?
    
    private var networkId: String {
        #if os(iOS)
        return "network-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown")"
        #else
        return "network-\(ProcessInfo.processInfo.globallyUniqueString.prefix(8))"
        #endif
    }
    
    init(encryptionService: EncryptionService) {
        self.encryptionService = encryptionService
        self.signingKey = Curve25519.Signing.PrivateKey()
        
        webSocketService.delegate = self
    }
    
    func connect(to url: URL) {
        guard !isConnected else { return }
        
        do {
            let auth = try BridgeAuth.create(with: signingKey, networkId: networkId)
            bridgeURL = url
            webSocketService.connect(to: url, with: auth)
        } catch {
            connectionError = error.localizedDescription
        }
    }
    
    func disconnect() {
        webSocketService.disconnect()
        bridgeURL = nil
    }
    
    func sendMessage(_ packet: BitchatPacket) {
        guard isConnected else { return }
        
        do {
            // Convert BitchatPacket to BridgeMessage
            let bridgeMessage = try BridgeMessage(from: packet, sourceNetwork: networkId)
            
            let data = try bridgeMessage.serialize()
            webSocketService.send(data)
        } catch {
            print("Failed to send bridge message: \(error)")
        }
    }
    
    func sendHeartbeat() {
        guard isConnected else { return }
        
        let heartbeat = BridgeMessage(
            id: UUID().uuidString,
            type: .heartbeat,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: 1,
            payload: Data(),
            sourceNetwork: networkId
        )
        
        do {
            let data = try heartbeat.serialize()
            webSocketService.send(data)
        } catch {
            print("Failed to send heartbeat: \(error)")
        }
    }
}

extension BridgeClient: WebSocketServiceDelegate {
    func webSocketDidConnect() {
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionError = nil
        }
        delegate?.bridgeDidConnect(self)
    }
    
    func webSocketDidDisconnect(error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            if let error = error {
                self.connectionError = error.localizedDescription
            }
        }
        delegate?.bridgeDidDisconnect(self, error: error)
    }
    
    func webSocketDidReceiveMessage(_ data: Data) {
        do {
            let bridgeMessage = try BridgeMessage.deserialize(from: data)
            
            if bridgeMessage.type == .meshMessage {
                // Convert back to BitchatPacket
                let packet = try bridgeMessage.toBitchatPacket()
                delegate?.bridgeDidReceiveMessage(self, message: packet)
            } else if bridgeMessage.type == .heartbeat {
                // Handle heartbeat - could log or update connection status
                print("Received heartbeat from bridge")
            }
        } catch {
            print("Failed to process bridge message: \(error)")
        }
    }
}