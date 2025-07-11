import Foundation
import CryptoKit

struct BridgeAuth {
    let networkId: String
    let publicKey: String
    let signature: String
    let timestamp: UInt64
    
    static func create(with keyPair: Curve25519.Signing.PrivateKey, networkId: String) throws -> BridgeAuth {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let message = "\(networkId):\(timestamp)"
        let messageData = message.data(using: .utf8)!
        
        let signature = try keyPair.signature(for: messageData)
        let publicKey = keyPair.publicKey.rawRepresentation
        
        return BridgeAuth(
            networkId: networkId,
            publicKey: publicKey.hexString,
            signature: signature.hexString,
            timestamp: timestamp
        )
    }
}

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
    
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}