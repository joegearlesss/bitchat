import Foundation

class BridgeManager: ObservableObject {
    @Published var activeBridges: [BridgeConnection] = []
    @Published var isEnabled = false
    
    private let encryptionService: EncryptionService
    private var bridgeClients: [String: BridgeClient] = [:]
    
    weak var meshService: BluetoothMeshService?
    
    struct BridgeConnection: Identifiable, Codable {
        let id = UUID()
        let url: URL
        let name: String
        let isConnected: Bool
        let lastConnected: Date?
        
        enum CodingKeys: String, CodingKey {
            case url, name, isConnected, lastConnected
        }
        
        init(url: URL, name: String, isConnected: Bool = false, lastConnected: Date? = nil) {
            self.url = url
            self.name = name
            self.isConnected = isConnected
            self.lastConnected = lastConnected
        }
    }
    
    init(encryptionService: EncryptionService) {
        self.encryptionService = encryptionService
        loadBridgeConnections()
        setupNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func addBridge(url: URL, name: String) {
        let connection = BridgeConnection(
            url: url,
            name: name,
            isConnected: false,
            lastConnected: nil
        )
        
        activeBridges.append(connection)
        saveBridgeConnections()
        
        if isEnabled {
            connectToBridge(connection)
        }
    }
    
    func removeBridge(id: UUID) {
        if let index = activeBridges.firstIndex(where: { $0.id == id }) {
            let connection = activeBridges[index]
            disconnectFromBridge(connection)
            activeBridges.remove(at: index)
            saveBridgeConnections()
        }
    }
    
    func enableBridges() {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: "bridgeEnabled")
        
        for connection in activeBridges {
            connectToBridge(connection)
        }
    }
    
    func disableBridges() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: "bridgeEnabled")
        
        for connection in activeBridges {
            disconnectFromBridge(connection)
        }
    }
    
    private func connectToBridge(_ connection: BridgeConnection) {
        let client = BridgeClient(encryptionService: encryptionService)
        client.delegate = self
        
        bridgeClients[connection.id.uuidString] = client
        client.connect(to: connection.url)
    }
    
    private func disconnectFromBridge(_ connection: BridgeConnection) {
        if let client = bridgeClients[connection.id.uuidString] {
            client.disconnect()
            bridgeClients.removeValue(forKey: connection.id.uuidString)
        }
    }
    
    func relayMessage(_ packet: BitchatPacket) {
        guard isEnabled else { return }
        
        // Don't relay if message is too old
        let messageAge = Date().timeIntervalSince1970 - Double(packet.timestamp) / 1000
        guard messageAge < 300 else { return } // 5 minutes max age
        
        // Don't relay if TTL is too low
        guard packet.ttl > 1 else { return }
        
        for client in bridgeClients.values {
            if client.isConnected {
                client.sendMessage(packet)
            }
        }
    }
    
    private func loadBridgeConnections() {
        isEnabled = UserDefaults.standard.bool(forKey: "bridgeEnabled")
        
        if let data = UserDefaults.standard.data(forKey: "bridgeConnections"),
           let connections = try? JSONDecoder().decode([BridgeConnection].self, from: data) {
            activeBridges = connections
        }
    }
    
    private func saveBridgeConnections() {
        if let data = try? JSONEncoder().encode(activeBridges) {
            UserDefaults.standard.set(data, forKey: "bridgeConnections")
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBridgeMessageRelay),
            name: .bridgeMessageRelay,
            object: nil
        )
    }
    
    @objc private func handleBridgeMessageRelay(_ notification: Notification) {
        guard let packet = notification.object as? BitchatPacket else { return }
        relayMessage(packet)
    }
    
    private func updateBridgeConnection(_ connection: BridgeConnection, isConnected: Bool) {
        if let index = activeBridges.firstIndex(where: { $0.id == connection.id }) {
            activeBridges[index] = BridgeConnection(
                url: connection.url,
                name: connection.name,
                isConnected: isConnected,
                lastConnected: isConnected ? Date() : connection.lastConnected
            )
            saveBridgeConnections()
        }
    }
}

extension BridgeManager: BridgeClientDelegate {
    func bridgeDidConnect(_ bridge: BridgeClient) {
        DispatchQueue.main.async {
            if let url = bridge.bridgeURL,
               let connection = self.activeBridges.first(where: { $0.url == url }) {
                self.updateBridgeConnection(connection, isConnected: true)
            }
        }
    }
    
    func bridgeDidDisconnect(_ bridge: BridgeClient, error: Error?) {
        DispatchQueue.main.async {
            if let url = bridge.bridgeURL,
               let connection = self.activeBridges.first(where: { $0.url == url }) {
                self.updateBridgeConnection(connection, isConnected: false)
            }
        }
    }
    
    func bridgeDidReceiveMessage(_ bridge: BridgeClient, message: BitchatPacket) {
        // Inject message into local mesh network
        meshService?.injectBridgeMessage(message)
    }
}

extension Notification.Name {
    static let bridgeMessageRelay = Notification.Name("bridgeMessageRelay")
}