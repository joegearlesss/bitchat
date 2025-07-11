import Foundation

struct BridgeMessage: Codable {
    let id: String
    let type: MessageType
    let timestamp: UInt64
    let ttl: UInt8
    let payload: Data
    let sourceNetwork: String
    let targetNetwork: String?
    let signature: Data?
    
    enum MessageType: UInt8, Codable {
        case meshMessage = 0x01
        case bridgeControl = 0x02
        case heartbeat = 0x03
    }
    
    init(id: String, type: MessageType, timestamp: UInt64, ttl: UInt8, payload: Data, sourceNetwork: String, targetNetwork: String? = nil, signature: Data? = nil) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.ttl = ttl
        self.payload = payload
        self.sourceNetwork = sourceNetwork
        self.targetNetwork = targetNetwork
        self.signature = signature
    }
    
    func serialize() throws -> Data {
        let payloadLength = UInt32(payload.count)
        let signatureLength = signature?.count ?? 0
        let totalLength = 16 + 1 + 8 + 1 + 4 + payload.count + signatureLength
        
        var data = Data(capacity: totalLength)
        
        // ID (16 bytes, padded)
        let idData = id.data(using: .utf8)?.prefix(16) ?? Data()
        data.append(idData)
        data.append(Data(count: 16 - idData.count)) // Padding
        
        // Type (1 byte)
        data.append(type.rawValue)
        
        // Timestamp (8 bytes, big endian)
        data.append(withUnsafeBytes(of: timestamp.bigEndian) { Data($0) })
        
        // TTL (1 byte)
        data.append(ttl)
        
        // Payload length (4 bytes, big endian)
        data.append(withUnsafeBytes(of: payloadLength.bigEndian) { Data($0) })
        
        // Payload
        data.append(payload)
        
        // Signature (optional)
        if let signature = signature {
            data.append(signature)
        }
        
        return data
    }
    
    static func deserialize(from data: Data) throws -> BridgeMessage {
        guard data.count >= 30 else { // Minimum size without payload
            throw BridgeError.invalidMessageFormat
        }
        
        var offset = 0
        
        // ID
        let idData = data.subdata(in: offset..<offset+16)
        let id = String(data: idData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        offset += 16
        
        // Type
        guard let type = MessageType(rawValue: data[offset]) else {
            throw BridgeError.invalidMessageType
        }
        offset += 1
        
        // Timestamp
        let timestamp = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        offset += 8
        
        // TTL
        let ttl = data[offset]
        offset += 1
        
        // Payload length
        let payloadLength = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
        
        // Payload
        guard offset + Int(payloadLength) <= data.count else {
            throw BridgeError.invalidMessageFormat
        }
        let payload = data.subdata(in: offset..<offset+Int(payloadLength))
        offset += Int(payloadLength)
        
        // Signature (remaining bytes)
        let signature = offset < data.count ? data.subdata(in: offset..<data.count) : nil
        
        return BridgeMessage(
            id: id,
            type: type,
            timestamp: timestamp,
            ttl: ttl,
            payload: payload,
            sourceNetwork: "", // Will be set by bridge context
            targetNetwork: nil,
            signature: signature
        )
    }
    
    var messageID: String {
        return id
    }
}

enum BridgeError: Error {
    case invalidMessageFormat
    case invalidMessageType
    case authenticationFailed
    case connectionFailed
    case serializationFailed
    case deserializationFailed
}

// Extension to convert BitchatPacket to BridgeMessage and vice versa
extension BridgeMessage {
    init(from packet: BitchatPacket, sourceNetwork: String) throws {
        guard let packetData = packet.toBinaryData() else {
            throw BridgeError.serializationFailed
        }
        
        self.init(
            id: UUID().uuidString,
            type: .meshMessage,
            timestamp: packet.timestamp,
            ttl: packet.ttl,
            payload: packetData,
            sourceNetwork: sourceNetwork
        )
    }
    
    func toBitchatPacket() throws -> BitchatPacket {
        guard type == .meshMessage else {
            throw BridgeError.invalidMessageType
        }
        
        guard let packet = BitchatPacket.from(payload) else {
            throw BridgeError.deserializationFailed
        }
        
        return packet
    }
}