import XCTest
@testable import bitchat

class BridgeMessageTests: XCTestCase {
    
    func testBridgeMessageSerialization() {
        let message = BridgeMessage(
            id: "test-id-123",
            type: .meshMessage,
            timestamp: 1234567890123,
            ttl: 5,
            payload: Data([1, 2, 3, 4, 5]),
            sourceNetwork: "test-network"
        )
        
        XCTAssertNoThrow(try message.serialize())
        
        let serialized = try! message.serialize()
        XCTAssertGreaterThan(serialized.count, 30) // Minimum expected size
        
        let deserialized = try! BridgeMessage.deserialize(from: serialized)
        
        XCTAssertEqual(deserialized.id, message.id)
        XCTAssertEqual(deserialized.type, message.type)
        XCTAssertEqual(deserialized.timestamp, message.timestamp)
        XCTAssertEqual(deserialized.ttl, message.ttl)
        XCTAssertEqual(deserialized.payload, message.payload)
    }
    
    func testBridgeMessageWithSignature() {
        let signature = Data([0x01, 0x02, 0x03, 0x04])
        let message = BridgeMessage(
            id: "test-id-456",
            type: .bridgeControl,
            timestamp: 1234567890456,
            ttl: 3,
            payload: Data("control message".utf8),
            sourceNetwork: "test-network",
            signature: signature
        )
        
        let serialized = try! message.serialize()
        let deserialized = try! BridgeMessage.deserialize(from: serialized)
        
        XCTAssertEqual(deserialized.signature, signature)
    }
    
    func testBridgeMessageHeartbeat() {
        let message = BridgeMessage(
            id: "heartbeat-789",
            type: .heartbeat,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: 1,
            payload: Data(),
            sourceNetwork: "test-network"
        )
        
        let serialized = try! message.serialize()
        let deserialized = try! BridgeMessage.deserialize(from: serialized)
        
        XCTAssertEqual(deserialized.type, .heartbeat)
        XCTAssertEqual(deserialized.ttl, 1)
        XCTAssertTrue(deserialized.payload.isEmpty)
    }
    
    func testBridgeMessageFromBitchatPacket() {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 5,
            senderID: "test-sender",
            payload: Data("test message".utf8)
        )
        
        XCTAssertNoThrow(try BridgeMessage(from: packet, sourceNetwork: "test-network"))
        
        let bridgeMessage = try! BridgeMessage(from: packet, sourceNetwork: "test-network")
        
        XCTAssertEqual(bridgeMessage.type, .meshMessage)
        XCTAssertEqual(bridgeMessage.ttl, packet.ttl)
        XCTAssertEqual(bridgeMessage.sourceNetwork, "test-network")
        XCTAssertFalse(bridgeMessage.id.isEmpty)
    }
    
    func testBridgeMessageToBitchatPacket() {
        // First create a BitchatPacket
        let originalPacket = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 5,
            senderID: "test-sender",
            payload: Data("test message".utf8)
        )
        
        // Convert to BridgeMessage
        let bridgeMessage = try! BridgeMessage(from: originalPacket, sourceNetwork: "test-network")
        
        // Convert back to BitchatPacket
        XCTAssertNoThrow(try bridgeMessage.toBitchatPacket())
        
        let convertedPacket = try! bridgeMessage.toBitchatPacket()
        
        XCTAssertEqual(convertedPacket.type, originalPacket.type)
        XCTAssertEqual(convertedPacket.ttl, originalPacket.ttl)
        // Note: payload will be different due to serialization/deserialization
    }
    
    func testInvalidBridgeMessageDeserialization() {
        // Test with too small data
        let tooSmallData = Data([1, 2, 3])
        XCTAssertThrowsError(try BridgeMessage.deserialize(from: tooSmallData)) { error in
            XCTAssertTrue(error is BridgeError)
            if case BridgeError.invalidMessageFormat = error {
                // Expected error
            } else {
                XCTFail("Expected invalidMessageFormat error")
            }
        }
        
        // Test with invalid message type
        var invalidData = Data(count: 30)
        invalidData[16] = 0xFF // Invalid message type
        XCTAssertThrowsError(try BridgeMessage.deserialize(from: invalidData)) { error in
            XCTAssertTrue(error is BridgeError)
            if case BridgeError.invalidMessageType = error {
                // Expected error
            } else {
                XCTFail("Expected invalidMessageType error")
            }
        }
    }
    
    func testBridgeMessageIDGeneration() {
        let message1 = BridgeMessage(
            id: "test-id-1",
            type: .meshMessage,
            timestamp: 1234567890,
            ttl: 5,
            payload: Data("message 1".utf8),
            sourceNetwork: "network-1"
        )
        
        let message2 = BridgeMessage(
            id: "test-id-2",
            type: .meshMessage,
            timestamp: 1234567891,
            ttl: 5,
            payload: Data("message 2".utf8),
            sourceNetwork: "network-1"
        )
        
        XCTAssertNotEqual(message1.messageID, message2.messageID)
        XCTAssertEqual(message1.messageID, message1.id)
        XCTAssertEqual(message2.messageID, message2.id)
    }
}