//
// WiFiBridgeService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Network
import CryptoKit
import Combine

@MainActor
class WiFiBridgeService: ObservableObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var bridgeEndpoints: [URL] = []
    private let encryptionService: EncryptionService
    private weak var meshService: BluetoothMeshService?
    private var sessionId: String?
    private var heartbeatTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var isIntentionalDisconnect = false
    
    @Published var isConnected = false
    @Published var bridgeStatus: BridgeStatus = .disconnected
    @Published var currentEndpoint: URL?
    @Published var connectionLatency: TimeInterval = 0
    
    enum BridgeStatus {
        case disconnected
        case connecting
        case connected
        case error(String)
        case reconnecting
    }
    
    // Default bridge endpoints - update with your worker URLs
    private let defaultEndpoints = [
        "wss://bitchat-bridge-staging.shirato.workers.dev/bridge/global"
    ]
    
    init(encryptionService: EncryptionService) {
        self.encryptionService = encryptionService
        loadBridgeEndpoints()
    }
    
    func setMeshService(_ meshService: BluetoothMeshService) {
        self.meshService = meshService
    }
    
    // MARK: - Connection Management
    
    func connectToBridge() async throws {
        guard !isConnected else { return }
        
        isIntentionalDisconnect = false
        bridgeStatus = .connecting
        
        // Try each endpoint until one works
        for endpoint in bridgeEndpoints {
            do {
                try await connectToEndpoint(endpoint)
                currentEndpoint = endpoint
                bridgeStatus = .connected
                isConnected = true
                reconnectAttempts = 0
                startHeartbeat()
                return
            } catch {
                print("Failed to connect to \(endpoint): \(error)")
                continue
            }
        }
        
        // If we get here, all endpoints failed
        bridgeStatus = .error("All bridge endpoints failed")
        throw BridgeError.connectionFailed
    }
    
    private func connectToEndpoint(_ endpoint: URL) async throws {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: endpoint)
        
        webSocketTask?.resume()
        
        // Start listening for messages
        startListening()
        
        // Wait for welcome message to confirm connection
        try await waitForWelcomeMessage()
    }
    
    private func waitForWelcomeMessage() async throws {
        return try await withTimeout(seconds: 10) {
            while true {
                let message = try await self.webSocketTask?.receive()
                
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["type"] as? String == "welcome" {
                        self.sessionId = json["sessionId"] as? String
                        return
                    }
                case .data(let data):
                    // Handle binary welcome message if needed
                    break
                case .none:
                    throw BridgeError.connectionFailed
                @unknown default:
                    break
                }
            }
        }
    }
    
    func disconnectFromBridge() {
        isIntentionalDisconnect = true
        stopHeartbeat()
        stopReconnectTimer()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        isConnected = false
        bridgeStatus = .disconnected
        currentEndpoint = nil
        sessionId = nil
    }
    
    // MARK: - Message Handling
    
    func sendMessage(_ packet: BitchatPacket) async throws {
        guard isConnected, let webSocketTask = webSocketTask else {
            throw BridgeError.notConnected
        }
        
        let bridgeMessage = BridgeMessage(
            type: "data",
            payload: BridgePayload(
                encryptedData: Array(packet.encryptedPayload),
                signature: Array(packet.signature),
                ttl: Int(packet.ttl),
                timestamp: Int(Date().timeIntervalSince1970 * 1000)
            )
        )
        
        let messageData = try JSONEncoder().encode(bridgeMessage)
        let messageString = String(data: messageData, encoding: .utf8)!
        
        try await webSocketTask.send(.string(messageString))
    }
    
    private func startListening() {
        Task {
            while isConnected && webSocketTask != nil {
                do {
                    let message = try await webSocketTask?.receive()
                    await handleReceivedMessage(message)
                } catch {
                    if !isIntentionalDisconnect {
                        print("WebSocket receive error: \(error)")
                        await handleConnectionError(error)
                    }
                    break
                }
            }
        }
    }
    
    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message?) async {
        guard let message = message else { return }
        
        switch message {
        case .string(let text):
            await handleStringMessage(text)
        case .data(let data):
            await handleBinaryMessage(data)
        @unknown default:
            break
        }
    }
    
    private func handleStringMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        let messageType = json["type"] as? String
        
        switch messageType {
        case "data":
            await handleDataMessage(json)
        case "heartbeat_ack":
            // Update connection latency if needed
            break
        case "ping":
            await sendPong()
        case "error":
            let errorMessage = json["message"] as? String ?? "Unknown error"
            bridgeStatus = .error(errorMessage)
        default:
            break
        }
    }
    
    private func handleDataMessage(_ json: [String: Any]) async {
        guard let payload = json["payload"] as? [String: Any],
              let encryptedDataArray = payload["encryptedData"] as? [Int],
              let signatureArray = payload["signature"] as? [Int],
              let ttl = payload["ttl"] as? Int else {
            return
        }
        
        let encryptedData = Data(encryptedDataArray.map { UInt8($0) })
        let signature = Data(signatureArray.map { UInt8($0) })
        
        // Create BitchatPacket from bridge message
        let packet = BitchatPacket(
            version: 1,
            messageType: .message,
            ttl: UInt8(max(0, ttl - 1)), // Decrement TTL
            senderID: "bridge", // Special sender ID for bridge messages
            recipientID: nil,
            encryptedPayload: encryptedData,
            signature: signature
        )
        
        // Forward to mesh service for processing
        await meshService?.handleBridgeMessage(packet)
    }
    
    private func handleBinaryMessage(_ data: Data) async {
        // Handle binary bridge messages if needed
        // For now, we primarily use JSON messages
    }
    
    private func sendPong() async {
        guard let webSocketTask = webSocketTask else { return }
        
        let pongMessage = ["type": "pong", "timestamp": Int(Date().timeIntervalSince1970 * 1000)]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: pongMessage)
            let text = String(data: data, encoding: .utf8)!
            try await webSocketTask.send(.string(text))
        } catch {
            print("Failed to send pong: \(error)")
        }
    }
    
    // MARK: - Heartbeat Management
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task {
                await self.sendHeartbeat()
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func sendHeartbeat() async {
        guard let webSocketTask = webSocketTask else { return }
        
        let heartbeatMessage = ["type": "heartbeat", "timestamp": Int(Date().timeIntervalSince1970 * 1000)]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: heartbeatMessage)
            let text = String(data: data, encoding: .utf8)!
            try await webSocketTask.send(.string(text))
        } catch {
            print("Heartbeat failed: \(error)")
            await handleConnectionError(error)
        }
    }
    
    // MARK: - Reconnection Logic
    
    private func handleConnectionError(_ error: Error) async {
        guard !isIntentionalDisconnect else { return }
        
        isConnected = false
        bridgeStatus = .reconnecting
        
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0) // Exponential backoff, max 30s
            
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task {
                    do {
                        try await self.connectToBridge()
                    } catch {
                        print("Reconnection attempt \(self.reconnectAttempts) failed: \(error)")
                    }
                }
            }
        } else {
            bridgeStatus = .error("Max reconnection attempts reached")
        }
    }
    
    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    // MARK: - Configuration
    
    private func loadBridgeEndpoints() {
        // Load from UserDefaults or use defaults
        if let savedEndpoints = UserDefaults.standard.array(forKey: "bitchat.bridgeEndpoints") as? [String] {
            bridgeEndpoints = savedEndpoints.compactMap { URL(string: $0) }
        }
        
        if bridgeEndpoints.isEmpty {
            bridgeEndpoints = defaultEndpoints.compactMap { URL(string: $0) }
        }
    }
    
    func updateBridgeEndpoints(_ endpoints: [URL]) {
        bridgeEndpoints = endpoints
        let endpointStrings = endpoints.map { $0.absoluteString }
        UserDefaults.standard.set(endpointStrings, forKey: "bitchat.bridgeEndpoints")
    }
}

// MARK: - Supporting Types

struct BridgeMessage: Codable {
    let type: String
    let payload: BridgePayload?
    let channel: String?
    
    init(type: String, payload: BridgePayload? = nil, channel: String? = nil) {
        self.type = type
        self.payload = payload
        self.channel = channel
    }
}

struct BridgePayload: Codable {
    let encryptedData: [Int]
    let signature: [Int]
    let ttl: Int
    let timestamp: Int
}

enum BridgeError: Error {
    case connectionFailed
    case notConnected
    case invalidMessage
    case timeout
}

// MARK: - Utility Extensions

extension WiFiBridgeService {
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BridgeError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - BluetoothMeshService Extension

extension BluetoothMeshService {
    func handleBridgeMessage(_ packet: BitchatPacket) async {
        // Process bridge message similar to BLE messages
        // This will be called from WiFiBridgeService when messages arrive
        
        // Add bridge metadata to track transport type
        var bridgePacket = packet
        // You could add a transport type field to BitchatPacket if needed
        
        // Process through existing message handling pipeline
        DispatchQueue.main.async {
            // Forward to existing packet processing
            // This integrates with the existing message handling in BluetoothMeshService
        }
    }
    
    func sendViaBridge(_ packet: BitchatPacket) async throws {
        // This will be called by the hybrid transport manager
        // to send messages via WiFi bridge when BLE is not available
    }
}