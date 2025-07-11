import XCTest
@testable import bitchat

class BridgeManagerTests: XCTestCase {
    var bridgeManager: BridgeManager!
    var mockEncryptionService: EncryptionService!
    
    override func setUp() {
        super.setUp()
        mockEncryptionService = EncryptionService()
        bridgeManager = BridgeManager(encryptionService: mockEncryptionService)
    }
    
    override func tearDown() {
        bridgeManager = nil
        mockEncryptionService = nil
        super.tearDown()
    }
    
    func testAddBridge() {
        let url = URL(string: "wss://test.example.com/bridge/connect")!
        bridgeManager.addBridge(url: url, name: "Test Bridge")
        
        XCTAssertEqual(bridgeManager.activeBridges.count, 1)
        XCTAssertEqual(bridgeManager.activeBridges.first?.name, "Test Bridge")
        XCTAssertEqual(bridgeManager.activeBridges.first?.url, url)
        XCTAssertFalse(bridgeManager.activeBridges.first?.isConnected ?? true)
    }
    
    func testRemoveBridge() {
        let url = URL(string: "wss://test.example.com/bridge/connect")!
        bridgeManager.addBridge(url: url, name: "Test Bridge")
        
        let bridgeId = bridgeManager.activeBridges.first!.id
        bridgeManager.removeBridge(id: bridgeId)
        
        XCTAssertEqual(bridgeManager.activeBridges.count, 0)
    }
    
    func testEnableBridges() {
        XCTAssertFalse(bridgeManager.isEnabled)
        
        bridgeManager.enableBridges()
        
        XCTAssertTrue(bridgeManager.isEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "bridgeEnabled"))
    }
    
    func testDisableBridges() {
        bridgeManager.enableBridges()
        XCTAssertTrue(bridgeManager.isEnabled)
        
        bridgeManager.disableBridges()
        
        XCTAssertFalse(bridgeManager.isEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "bridgeEnabled"))
    }
    
    func testBridgeConnectionPersistence() {
        let url = URL(string: "wss://test.example.com/bridge/connect")!
        bridgeManager.addBridge(url: url, name: "Test Bridge")
        
        // Create new bridge manager to test persistence
        let newBridgeManager = BridgeManager(encryptionService: mockEncryptionService)
        
        XCTAssertEqual(newBridgeManager.activeBridges.count, 1)
        XCTAssertEqual(newBridgeManager.activeBridges.first?.name, "Test Bridge")
        XCTAssertEqual(newBridgeManager.activeBridges.first?.url, url)
    }
    
    func testRelayMessageWhenDisabled() {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 5,
            senderID: "test-sender",
            payload: Data("test message".utf8)
        )
        
        // Should not relay when disabled
        bridgeManager.disableBridges()
        bridgeManager.relayMessage(packet)
        
        // No way to directly test this without mocking, but at least ensure no crash
        XCTAssertFalse(bridgeManager.isEnabled)
    }
    
    func testRelayMessageWithLowTTL() {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 1, // Low TTL should not be relayed
            senderID: "test-sender",
            payload: Data("test message".utf8)
        )
        
        bridgeManager.enableBridges()
        bridgeManager.relayMessage(packet)
        
        // Should not relay messages with TTL <= 1
        // No direct way to test without mocking, but ensures no crash
        XCTAssertTrue(bridgeManager.isEnabled)
    }
    
    func testRelayMessageWithOldTimestamp() {
        // Create packet with old timestamp (more than 5 minutes ago)
        let oldTimestamp = UInt64((Date().timeIntervalSince1970 - 400) * 1000) // 400 seconds ago
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("test-sender".utf8),
            recipientID: nil,
            timestamp: oldTimestamp,
            payload: Data("test message".utf8),
            signature: nil,
            ttl: 5
        )
        
        bridgeManager.enableBridges()
        bridgeManager.relayMessage(packet)
        
        // Should not relay old messages
        // No direct way to test without mocking, but ensures no crash
        XCTAssertTrue(bridgeManager.isEnabled)
    }
}