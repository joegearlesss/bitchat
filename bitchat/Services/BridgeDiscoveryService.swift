//
// BridgeDiscoveryService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Network
import Combine

@MainActor
class BridgeDiscoveryService: ObservableObject {
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "bitchat.networkMonitor")
    private weak var meshService: BluetoothMeshService?
    
    @Published var availableBridges: [BridgeEndpoint] = []
    @Published var networkStatus: NetworkStatus = .unknown
    @Published var isDiscovering = false
    
    enum NetworkStatus {
        case unknown
        case cellular
        case wifi
        case offline
    }
    
    struct BridgeEndpoint {
        let url: URL
        let region: String
        let latency: TimeInterval?
        let capacity: Int
        let isHealthy: Bool
        let lastChecked: Date
        
        var priority: Int {
            // Lower is better
            var score = 0
            
            // Prefer healthy bridges
            if !isHealthy { score += 1000 }
            
            // Prefer lower latency
            if let latency = latency {
                score += Int(latency * 100) // Convert to ms-like score
            } else {
                score += 500 // Unknown latency penalty
            }
            
            // Prefer higher capacity
            score += max(0, 100 - capacity)
            
            return score
        }
    }
    
    // Default bridge discovery endpoints - update with your worker URLs
    private let discoveryEndpoints = [
        "https://bitchat-bridge-staging.shirato.workers.dev/bridge/global/stats"
    ]
    
    init() {
        startNetworkMonitoring()
    }
    
    deinit {
        networkMonitor.cancel()
    }
    
    func setMeshService(_ meshService: BluetoothMeshService) {
        self.meshService = meshService
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateNetworkStatus(path)
            }
        }
        networkMonitor.start(queue: networkQueue)
    }
    
    private func updateNetworkStatus(_ path: NWPath) {
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi) {
                networkStatus = .wifi
            } else if path.usesInterfaceType(.cellular) {
                networkStatus = .cellular
            } else {
                networkStatus = .unknown
            }
        case .unsatisfied, .requiresConnection:
            networkStatus = .offline
        @unknown default:
            networkStatus = .unknown
        }
        
        // Trigger bridge discovery when network becomes available
        if networkStatus != .offline && !isDiscovering {
            Task {
                await startDiscovery()
            }
        }
    }
    
    // MARK: - Bridge Discovery
    
    func startDiscovery() async {
        guard networkStatus != .offline else { return }
        guard !isDiscovering else { return }
        
        isDiscovering = true
        
        do {
            // Discover bridges from multiple sources
            let discoveredBridges = await withTaskGroup(of: [BridgeEndpoint].self) { group in
                var allBridges: [BridgeEndpoint] = []
                
                // Add tasks for each discovery endpoint
                for endpoint in discoveryEndpoints {
                    group.addTask {
                        await self.discoverFromEndpoint(endpoint)
                    }
                }
                
                // Collect results
                for await bridges in group {
                    allBridges.append(contentsOf: bridges)
                }
                
                return allBridges
            }
            
            // Test connectivity and latency for each bridge
            let testedBridges = await testBridgeConnectivity(discoveredBridges)
            
            // Sort by priority (best first)
            availableBridges = testedBridges.sorted { $0.priority < $1.priority }
            
        } catch {
            print("Bridge discovery failed: \(error)")
        }
        
        isDiscovering = false
    }
    
    private func discoverFromEndpoint(_ endpoint: String) async -> [BridgeEndpoint] {
        guard let url = URL(string: endpoint) else { return [] }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            
            let bridgeList = try JSONDecoder().decode(BridgeList.self, from: data)
            
            return bridgeList.endpoints.compactMap { endpoint in
                guard let bridgeUrl = createBridgeURL(from: endpoint) else { return nil }
                
                return BridgeEndpoint(
                    url: bridgeUrl,
                    region: endpoint.region,
                    latency: nil, // Will be tested later
                    capacity: 100, // Default capacity
                    isHealthy: endpoint.status == "healthy",
                    lastChecked: Date()
                )
            }
            
        } catch {
            print("Failed to discover bridges from \(endpoint): \(error)")
            return []
        }
    }
    
    private func createBridgeURL(from endpoint: BridgeEndpointInfo) -> URL? {
        // Convert HTTP discovery endpoint to WebSocket bridge endpoint
        let baseURL = endpoint.id == "global" ? 
            "wss://bridge.bitchat.app" : 
            "wss://bridge-\(endpoint.region).bitchat.app"
        
        return URL(string: "\(baseURL)/bridge/\(endpoint.id)")
    }
    
    private func testBridgeConnectivity(_ bridges: [BridgeEndpoint]) async -> [BridgeEndpoint] {
        return await withTaskGroup(of: BridgeEndpoint.self) { group in
            var testedBridges: [BridgeEndpoint] = []
            
            for bridge in bridges {
                group.addTask {
                    await self.testBridge(bridge)
                }
            }
            
            for await testedBridge in group {
                testedBridges.append(testedBridge)
            }
            
            return testedBridges
        }
    }
    
    private func testBridge(_ bridge: BridgeEndpoint) async -> BridgeEndpoint {
        let startTime = Date()
        
        do {
            // Test WebSocket connection
            let session = URLSession(configuration: .default)
            let webSocketTask = session.webSocketTask(with: bridge.url)
            
            webSocketTask.resume()
            
            // Try to receive welcome message with timeout
            let message = try await withTimeout(seconds: 5) {
                try await webSocketTask.receive()
            }
            
            webSocketTask.cancel(with: .goingAway, reason: nil)
            
            let latency = Date().timeIntervalSince(startTime)
            
            // Check if we got a valid welcome message
            var isHealthy = false
            if case .string(let text) = message,
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["type"] as? String == "welcome" {
                isHealthy = true
            }
            
            return BridgeEndpoint(
                url: bridge.url,
                region: bridge.region,
                latency: latency,
                capacity: bridge.capacity,
                isHealthy: isHealthy,
                lastChecked: Date()
            )
            
        } catch {
            return BridgeEndpoint(
                url: bridge.url,
                region: bridge.region,
                latency: nil,
                capacity: bridge.capacity,
                isHealthy: false,
                lastChecked: Date()
            )
        }
    }
    
    func selectOptimalBridge() -> BridgeEndpoint? {
        return availableBridges.first { $0.isHealthy }
    }
    
    // MARK: - Periodic Updates
    
    func startPeriodicDiscovery() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in // Every 5 minutes
            Task {
                await self.startDiscovery()
            }
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BridgeDiscoveryError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Supporting Types

struct BridgeList: Codable {
    let endpoints: [BridgeEndpointInfo]
}

struct BridgeEndpointInfo: Codable {
    let id: String
    let region: String
    let status: String
}

enum BridgeDiscoveryError: Error {
    case timeout
    case networkUnavailable
    case invalidResponse
}