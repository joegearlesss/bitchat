//
// HybridTransportManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
import Network

@MainActor
class HybridTransportManager: ObservableObject {
    private let bluetoothService: BluetoothMeshService
    private let bridgeService: WiFiBridgeService
    private let discoveryService: BridgeDiscoveryService
    private let encryptionService: EncryptionService
    
    @Published var activeTransports: Set<TransportType> = []
    @Published var primaryTransport: TransportType = .bluetooth
    @Published var transportQuality: [TransportType: TransportQuality] = [:]
    @Published var isHybridModeEnabled = false
    @Published var autoSwitchEnabled = true
    
    enum TransportType: CaseIterable {
        case bluetooth
        case wifiBridge
        
        var displayName: String {
            switch self {
            case .bluetooth: return "Bluetooth Mesh"
            case .wifiBridge: return "WiFi Bridge"
            }
        }
        
        var priority: Int {
            switch self {
            case .bluetooth: return 1 // Higher priority (lower number)
            case .wifiBridge: return 2
            }
        }
    }
    
    struct TransportQuality {
        let isAvailable: Bool
        let connectionCount: Int
        let latency: TimeInterval?
        let reliability: Double // 0.0 to 1.0
        let batteryImpact: BatteryImpact
        
        enum BatteryImpact {
            case low, medium, high
        }
        
        var score: Double {
            var score = 0.0
            
            if isAvailable { score += 50.0 }
            score += Double(connectionCount) * 10.0
            
            if let latency = latency {
                score += max(0, 20.0 - latency) // Lower latency = higher score
            }
            
            score += reliability * 30.0
            
            // Battery impact penalty
            switch batteryImpact {
            case .low: score += 10.0
            case .medium: score += 5.0
            case .high: score -= 5.0
            }
            
            return score
        }
    }
    
    private var qualityUpdateTimer: Timer?
    private var transportSwitchCooldown: Date = Date()
    private let switchCooldownDuration: TimeInterval = 30.0 // 30 seconds
    
    init(bluetoothService: BluetoothMeshService, encryptionService: EncryptionService) {
        self.bluetoothService = bluetoothService
        self.encryptionService = encryptionService
        self.bridgeService = WiFiBridgeService(encryptionService: encryptionService)
        self.discoveryService = BridgeDiscoveryService()
        
        setupServices()
        startQualityMonitoring()
    }
    
    private func setupServices() {
        // Connect services
        bluetoothService.setBridgeService(bridgeService)
        bridgeService.setMeshService(bluetoothService)
        discoveryService.setMeshService(bluetoothService)
        
        // Start bridge discovery
        Task {
            await discoveryService.startDiscovery()
            discoveryService.startPeriodicDiscovery()
        }
    }
    
    // MARK: - Transport Management
    
    func enableHybridMode(_ enabled: Bool) {
        isHybridModeEnabled = enabled
        bluetoothService.enableHybridMode(enabled)
        
        if enabled {
            Task {
                await startHybridMode()
            }
        } else {
            stopHybridMode()
        }
    }
    
    private func startHybridMode() async {
        // Always start with Bluetooth
        activeTransports.insert(.bluetooth)
        
        // Try to connect to bridge
        do {
            try await bridgeService.connectToBridge()
            activeTransports.insert(.wifiBridge)
        } catch {
            print("Failed to connect to bridge: \(error)")
        }
        
        updatePrimaryTransport()
    }
    
    private func stopHybridMode() {
        bridgeService.disconnectFromBridge()
        activeTransports.remove(.wifiBridge)
        primaryTransport = .bluetooth
    }
    
    func sendMessage(_ packet: BitchatPacket) async throws {
        guard isHybridModeEnabled else {
            // Fallback to BLE only
            bluetoothService.broadcastPacket(packet)
            return
        }
        
        let strategy = determineTransportStrategy(for: packet)
        
        switch strategy {
        case .bluetoothOnly:
            bluetoothService.broadcastPacket(packet)
            
        case .bridgeOnly:
            try await bridgeService.sendMessage(packet)
            
        case .redundant:
            // Send via both transports for reliability
            bluetoothService.broadcastPacket(packet)
            try? await bridgeService.sendMessage(packet)
            
        case .adaptive:
            // Choose best transport based on current conditions
            let bestTransport = selectBestTransport()
            try await sendViaTransport(packet, transport: bestTransport)
        }
    }
    
    private func sendViaTransport(_ packet: BitchatPacket, transport: TransportType) async throws {
        switch transport {
        case .bluetooth:
            bluetoothService.broadcastPacket(packet)
        case .wifiBridge:
            try await bridgeService.sendMessage(packet)
        }
    }
    
    // MARK: - Transport Strategy
    
    enum TransportStrategy {
        case bluetoothOnly
        case bridgeOnly
        case redundant // Send via both
        case adaptive // Choose best available
    }
    
    private func determineTransportStrategy(for packet: BitchatPacket) -> TransportStrategy {
        let bluetoothAvailable = activeTransports.contains(.bluetooth) && !bluetoothService.connectedPeripherals.isEmpty
        let bridgeAvailable = activeTransports.contains(.wifiBridge) && bridgeService.isConnected
        
        // If only one transport is available, use it
        if bluetoothAvailable && !bridgeAvailable {
            return .bluetoothOnly
        } else if !bluetoothAvailable && bridgeAvailable {
            return .bridgeOnly
        } else if !bluetoothAvailable && !bridgeAvailable {
            // No transports available - this will fail, but let the caller handle it
            return .bluetoothOnly
        }
        
        // Both transports available - choose strategy based on message type
        if let payload = try? JSONDecoder().decode(MessagePayload.self, from: packet.payload) {
            // Private messages: use redundant sending for reliability
            if packet.recipientID != nil && packet.recipientID != SpecialRecipients.broadcast {
                return .redundant
            }
            
            // Channel messages: prefer bridge for wider reach
            if payload.content.hasPrefix("#") {
                return .bridgeOnly
            }
            
            // High-priority messages: use redundant
            if payload.content.contains("🚨") || payload.content.contains("URGENT") {
                return .redundant
            }
        }
        
        // Default: adaptive selection
        return .adaptive
    }
    
    private func selectBestTransport() -> TransportType {
        let availableTransports = activeTransports.filter { transport in
            switch transport {
            case .bluetooth:
                return !bluetoothService.connectedPeripherals.isEmpty
            case .wifiBridge:
                return bridgeService.isConnected
            }
        }
        
        // Select transport with best quality score
        let bestTransport = availableTransports.max { transport1, transport2 in
            let quality1 = transportQuality[transport1]?.score ?? 0
            let quality2 = transportQuality[transport2]?.score ?? 0
            return quality1 < quality2
        }
        
        return bestTransport ?? .bluetooth
    }
    
    // MARK: - Quality Monitoring
    
    private func startQualityMonitoring() {
        qualityUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task {
                await self.updateTransportQuality()
            }
        }
    }
    
    private func updateTransportQuality() async {
        // Update Bluetooth quality
        let bluetoothQuality = TransportQuality(
            isAvailable: bluetoothService.isConnected,
            connectionCount: bluetoothService.connectedPeripherals.count,
            latency: nil, // BLE latency is typically very low
            reliability: calculateBluetoothReliability(),
            batteryImpact: .medium
        )
        transportQuality[.bluetooth] = bluetoothQuality
        
        // Update Bridge quality
        let bridgeQuality = TransportQuality(
            isAvailable: bridgeService.isConnected,
            connectionCount: bridgeService.isConnected ? 1 : 0,
            latency: bridgeService.connectionLatency,
            reliability: calculateBridgeReliability(),
            batteryImpact: .low
        )
        transportQuality[.wifiBridge] = bridgeQuality
        
        // Auto-switch if enabled and conditions warrant it
        if autoSwitchEnabled {
            await considerTransportSwitch()
        }
    }
    
    private func calculateBluetoothReliability() -> Double {
        let connectedCount = bluetoothService.connectedPeripherals.count
        if connectedCount == 0 { return 0.0 }
        if connectedCount >= 3 { return 1.0 }
        return Double(connectedCount) / 3.0
    }
    
    private func calculateBridgeReliability() -> Double {
        guard bridgeService.isConnected else { return 0.0 }
        
        // Factor in latency
        if let latency = bridgeService.connectionLatency {
            if latency < 0.1 { return 1.0 }
            if latency < 0.5 { return 0.8 }
            if latency < 1.0 { return 0.6 }
            return 0.4
        }
        
        return 0.7 // Default for connected bridge
    }
    
    private func considerTransportSwitch() async {
        guard Date().timeIntervalSince(transportSwitchCooldown) > switchCooldownDuration else {
            return
        }
        
        let currentScore = transportQuality[primaryTransport]?.score ?? 0
        let bestTransport = selectBestTransport()
        let bestScore = transportQuality[bestTransport]?.score ?? 0
        
        // Switch if the best transport is significantly better
        if bestScore > currentScore + 20.0 && bestTransport != primaryTransport {
            primaryTransport = bestTransport
            transportSwitchCooldown = Date()
            print("Switched primary transport to: \(bestTransport.displayName)")
        }
    }
    
    // MARK: - Network Condition Handling
    
    func handleNetworkChange(_ status: BridgeDiscoveryService.NetworkStatus) {
        Task {
            switch status {
            case .offline:
                // Disable bridge, rely on Bluetooth only
                if activeTransports.contains(.wifiBridge) {
                    bridgeService.disconnectFromBridge()
                    activeTransports.remove(.wifiBridge)
                    primaryTransport = .bluetooth
                }
                
            case .wifi, .cellular:
                // Network available - try to connect bridge if hybrid mode enabled
                if isHybridModeEnabled && !activeTransports.contains(.wifiBridge) {
                    do {
                        try await bridgeService.connectToBridge()
                        activeTransports.insert(.wifiBridge)
                        updatePrimaryTransport()
                    } catch {
                        print("Failed to reconnect bridge after network change: \(error)")
                    }
                }
                
            case .unknown:
                break
            }
        }
    }
    
    private func updatePrimaryTransport() {
        primaryTransport = selectBestTransport()
    }
    
    // MARK: - Statistics and Monitoring
    
    func getTransportStatistics() -> [TransportType: [String: Any]] {
        var stats: [TransportType: [String: Any]] = [:]
        
        // Bluetooth stats
        stats[.bluetooth] = [
            "connected_peers": bluetoothService.connectedPeripherals.count,
            "is_connected": bluetoothService.isConnected,
            "battery_impact": "medium"
        ]
        
        // Bridge stats
        stats[.wifiBridge] = [
            "is_connected": bridgeService.isConnected,
            "latency": bridgeService.connectionLatency,
            "current_endpoint": bridgeService.currentEndpoint?.absoluteString ?? "none",
            "battery_impact": "low"
        ]
        
        return stats
    }
    
    func getRecommendedTransport() -> TransportType {
        return selectBestTransport()
    }
}