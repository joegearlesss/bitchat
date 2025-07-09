# WiFi Bridge Implementation Plan for bitchat

## Overview
This plan outlines the implementation of WiFi bridge support for bitchat, enabling users to connect through internet-based relay servers while maintaining the core privacy and security principles of the mesh network. The bridge will use Cloudflare Durable Objects as the relay infrastructure.

## Core Principles
- **Privacy-First**: Bridge servers cannot decrypt messages
- **Mesh Extension**: WiFi bridges extend the BLE mesh, not replace it
- **Fallback Only**: Internet connectivity is optional, BLE mesh remains primary
- **Zero Knowledge**: Bridge servers store no user data or message content
- **Ephemeral**: Bridge connections are temporary and session-based

## Architecture Overview

### High-Level Flow
1. **Local Mesh**: Users connect via BLE mesh as primary method
2. **Bridge Discovery**: When no local peers found, attempt bridge connection
3. **Relay Mode**: Bridge servers relay encrypted messages between mesh islands
4. **Seamless Integration**: Bridge messages appear identical to BLE messages
5. **Automatic Fallback**: Return to BLE-only when local peers available

### Security Model
- All messages remain end-to-end encrypted (Curve25519 + AES-256-GCM)
- Bridge servers see only encrypted payloads with routing metadata
- No user identity information transmitted to bridges
- Ephemeral session tokens for bridge authentication
- Optional onion routing through multiple bridges

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1-2)

#### 1.1 Cloudflare Durable Object Bridge Server
**File**: `bridge-server/` (new directory)

```typescript
// src/index.ts - Main Worker Entry Point
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    
    // Handle different endpoints
    if (path.startsWith('/bridge/')) {
      const bridgeId = path.split('/')[2] || 'global';
      const id = env.BRIDGE_RELAY.idFromName(bridgeId);
      const obj = env.BRIDGE_RELAY.get(id);
      return obj.fetch(request);
    }
    
    if (path === '/health') {
      return new Response('OK', { status: 200 });
    }
    
    if (path === '/bridges') {
      return new Response(JSON.stringify({
        endpoints: [
          { id: 'global', region: 'auto', status: 'healthy' },
          { id: 'us-east', region: 'us-east-1', status: 'healthy' },
          { id: 'eu-west', region: 'eu-west-1', status: 'healthy' },
          { id: 'ap-southeast', region: 'ap-southeast-1', status: 'healthy' }
        ]
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }
    
    return new Response('Not Found', { status: 404 });
  }
};

// src/bridge-relay.ts - Durable Object Implementation
export class BridgeRelay {
  private state: DurableObjectState;
  private env: Env;
  private sessions: Map<string, WebSocket>;
  private messageBuffer: Map<string, BufferedMessage[]>;
  private stats: BridgeStats;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.sessions = new Map();
    this.messageBuffer = new Map();
    this.stats = {
      totalMessages: 0,
      activeConnections: 0,
      uptime: Date.now(),
      messagesPerSecond: 0
    };
    
    // Clean up expired sessions every minute
    setInterval(() => this.cleanupExpiredSessions(), 60000);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    
    if (request.headers.get('Upgrade') === 'websocket') {
      return this.handleWebSocketUpgrade(request);
    }
    
    if (url.pathname.endsWith('/stats')) {
      return this.handleStatsRequest();
    }
    
    return new Response('Bad Request', { status: 400 });
  }

  private async handleWebSocketUpgrade(request: Request): Promise<Response> {
    const webSocketPair = new WebSocketPair();
    const [client, server] = Object.values(webSocketPair);
    
    const sessionId = this.generateSessionId();
    
    server.accept();
    this.sessions.set(sessionId, server);
    this.stats.activeConnections++;
    
    server.addEventListener('message', (event) => {
      this.handleMessage(sessionId, event.data);
    });
    
    server.addEventListener('close', () => {
      this.handleDisconnection(sessionId);
    });
    
    server.addEventListener('error', (error) => {
      console.error('WebSocket error:', error);
      this.handleDisconnection(sessionId);
    });
    
    // Send welcome message
    server.send(JSON.stringify({
      type: 'welcome',
      sessionId,
      timestamp: Date.now()
    }));
    
    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  private async handleMessage(sessionId: string, data: string | ArrayBuffer): Promise<void> {
    try {
      let message: BridgeMessage;
      
      if (typeof data === 'string') {
        message = JSON.parse(data);
      } else {
        // Handle binary message
        message = this.parseBinaryMessage(new Uint8Array(data));
      }
      
      await this.processMessage(sessionId, message);
      this.stats.totalMessages++;
      
    } catch (error) {
      console.error('Message processing error:', error);
      const ws = this.sessions.get(sessionId);
      if (ws) {
        ws.send(JSON.stringify({
          type: 'error',
          message: 'Invalid message format'
        }));
      }
    }
  }

  private async processMessage(sessionId: string, message: BridgeMessage): Promise<void> {
    switch (message.type) {
      case 'heartbeat':
        await this.handleHeartbeat(sessionId);
        break;
        
      case 'data':
        await this.relayMessage(sessionId, message);
        break;
        
      case 'subscribe':
        await this.handleSubscription(sessionId, message);
        break;
        
      case 'unsubscribe':
        await this.handleUnsubscription(sessionId, message);
        break;
        
      default:
        console.warn('Unknown message type:', message.type);
    }
  }

  private async handleHeartbeat(sessionId: string): Promise<void> {
    const ws = this.sessions.get(sessionId);
    if (ws) {
      ws.send(JSON.stringify({
        type: 'heartbeat_ack',
        timestamp: Date.now()
      }));
    }
  }

  private async relayMessage(fromSessionId: string, message: BridgeMessage): Promise<void> {
    const payload = message.payload;
    if (!payload || !payload.encryptedData) {
      return;
    }
    
    // Relay to all other connected sessions
    const relayMessage = {
      type: 'data',
      payload: {
        encryptedData: payload.encryptedData,
        signature: payload.signature,
        timestamp: Date.now(),
        ttl: Math.max(0, (payload.ttl || 6) - 1)
      }
    };
    
    // Don't relay if TTL is 0
    if (relayMessage.payload.ttl === 0) {
      return;
    }
    
    const messageStr = JSON.stringify(relayMessage);
    const promises: Promise<void>[] = [];
    
    this.sessions.forEach((ws, sessionId) => {
      if (sessionId !== fromSessionId) {
        promises.push(this.safeSend(ws, messageStr));
      }
    });
    
    // Also buffer message for offline sessions
    this.bufferMessage(fromSessionId, relayMessage);
    
    await Promise.all(promises);
  }

  private async handleSubscription(sessionId: string, message: BridgeMessage): Promise<void> {
    // Handle channel subscriptions if needed
    const ws = this.sessions.get(sessionId);
    if (ws) {
      ws.send(JSON.stringify({
        type: 'subscribe_ack',
        channel: message.channel
      }));
    }
  }

  private async handleUnsubscription(sessionId: string, message: BridgeMessage): Promise<void> {
    // Handle channel unsubscriptions if needed
    const ws = this.sessions.get(sessionId);
    if (ws) {
      ws.send(JSON.stringify({
        type: 'unsubscribe_ack',
        channel: message.channel
      }));
    }
  }

  private async safeSend(ws: WebSocket, message: string): Promise<void> {
    try {
      ws.send(message);
    } catch (error) {
      console.error('Failed to send message:', error);
    }
  }

  private bufferMessage(fromSessionId: string, message: any): void {
    const buffered: BufferedMessage = {
      message,
      timestamp: Date.now(),
      fromSessionId
    };
    
    // Add to buffer with expiry (24 hours)
    if (!this.messageBuffer.has(fromSessionId)) {
      this.messageBuffer.set(fromSessionId, []);
    }
    
    const buffer = this.messageBuffer.get(fromSessionId)!;
    buffer.push(buffered);
    
    // Keep only last 100 messages per session
    if (buffer.length > 100) {
      buffer.shift();
    }
  }

  private handleDisconnection(sessionId: string): void {
    this.sessions.delete(sessionId);
    this.stats.activeConnections--;
    
    // Clean up buffers after 24 hours
    setTimeout(() => {
      this.messageBuffer.delete(sessionId);
    }, 24 * 60 * 60 * 1000);
  }

  private cleanupExpiredSessions(): void {
    const now = Date.now();
    const expiredSessions: string[] = [];
    
    this.sessions.forEach((ws, sessionId) => {
      try {
        // Try to send a ping to check if connection is alive
        ws.send(JSON.stringify({ type: 'ping' }));
      } catch (error) {
        expiredSessions.push(sessionId);
      }
    });
    
    expiredSessions.forEach(sessionId => {
      this.handleDisconnection(sessionId);
    });
  }

  private generateSessionId(): string {
    return crypto.randomUUID();
  }

  private parseBinaryMessage(data: Uint8Array): BridgeMessage {
    // Parse binary bridge message format
    const view = new DataView(data.buffer);
    
    // Header parsing (8 bytes)
    const version = view.getUint8(0);
    const messageType = view.getUint8(1);
    const ttl = view.getUint8(2);
    const flags = view.getUint8(3);
    const payloadLength = view.getUint32(4);
    
    // Session token (32 bytes)
    const sessionToken = data.slice(8, 40);
    
    // Encrypted payload
    const encryptedPayload = data.slice(40, 40 + payloadLength);
    
    // Signature (64 bytes)
    const signature = data.slice(40 + payloadLength, 40 + payloadLength + 64);
    
    return {
      type: messageType === 0 ? 'data' : 'heartbeat',
      payload: {
        encryptedData: Array.from(encryptedPayload),
        signature: Array.from(signature),
        ttl,
        timestamp: Date.now()
      }
    };
  }

  private async handleStatsRequest(): Promise<Response> {
    const stats = {
      ...this.stats,
      activeConnections: this.sessions.size,
      uptime: Date.now() - this.stats.uptime,
      bufferedMessages: Array.from(this.messageBuffer.values())
        .reduce((total, buffer) => total + buffer.length, 0)
    };
    
    return new Response(JSON.stringify(stats), {
      headers: { 'Content-Type': 'application/json' }
    });
  }
}

// src/types.ts - Type Definitions
export interface Env {
  BRIDGE_RELAY: DurableObjectNamespace;
}

export interface BridgeMessage {
  type: 'heartbeat' | 'data' | 'subscribe' | 'unsubscribe';
  payload?: {
    encryptedData: number[];
    signature: number[];
    ttl?: number;
    timestamp: number;
  };
  channel?: string;
}

export interface BufferedMessage {
  message: any;
  timestamp: number;
  fromSessionId: string;
}

export interface BridgeStats {
  totalMessages: number;
  activeConnections: number;
  uptime: number;
  messagesPerSecond: number;
}
```

#### 1.2 Swift Bridge Service
**File**: `WiFiBridgeService.swift` (new file)

```swift
import Foundation
import Network
import CryptoKit

@MainActor
class WiFiBridgeService: ObservableObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var bridgeEndpoints: [URL] = []
    private let encryptionService: EncryptionService
    private let meshService: BluetoothMeshService
    
    @Published var isConnected = false
    @Published var bridgeStatus: BridgeStatus = .disconnected
    
    enum BridgeStatus {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    init(encryptionService: EncryptionService, meshService: BluetoothMeshService) {
        self.encryptionService = encryptionService
        self.meshService = meshService
        loadBridgeEndpoints()
    }
    
    // Core bridge functionality
    func connectToBridge() async throws { }
    func disconnectFromBridge() { }
    func sendMessage(_ message: MeshMessage) async throws { }
    private func handleIncomingMessage(_ data: Data) async { }
}
```

#### 1.3 Message Protocol Extensions
**File**: `MeshMessage.swift` (modify existing)

```swift
extension MeshMessage {
    enum TransportType: UInt8 {
        case bluetooth = 0
        case wifiBridge = 1
        case hybrid = 2
    }
    
    struct BridgeMetadata {
        let transportType: TransportType
        let bridgeId: String?
        let routingPath: [String]? // for onion routing
    }
    
    var bridgeMetadata: BridgeMetadata? {
        // Extract bridge-specific metadata
    }
}
```

### Phase 2: Integration & Discovery (Week 3-4)

#### 2.1 Bridge Discovery Service
**File**: `BridgeDiscoveryService.swift` (new file)

```swift
@MainActor
class BridgeDiscoveryService: ObservableObject {
    private let networkMonitor = NWPathMonitor()
    private let meshService: BluetoothMeshService
    
    @Published var availableBridges: [BridgeEndpoint] = []
    @Published var networkStatus: NetworkStatus = .unknown
    
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
    }
    
    func startDiscovery() async {
        // Monitor network changes
        // Discover available bridges
        // Test bridge connectivity and latency
        // Rank bridges by performance
    }
    
    func selectOptimalBridge() -> BridgeEndpoint? {
        // Select best bridge based on latency, capacity, health
    }
}
```

#### 2.2 Hybrid Transport Manager
**File**: `HybridTransportManager.swift` (new file)

```swift
@MainActor
class HybridTransportManager: ObservableObject {
    private let bluetoothService: BluetoothMeshService
    private let bridgeService: WiFiBridgeService
    private let discoveryService: BridgeDiscoveryService
    
    @Published var activeTransports: Set<TransportType> = []
    @Published var primaryTransport: TransportType = .bluetooth
    
    enum TransportType {
        case bluetooth
        case wifiBridge
    }
    
    func sendMessage(_ message: MeshMessage) async throws {
        // Intelligent routing based on:
        // - Available transports
        // - Message priority
        // - Network conditions
        // - Battery level
    }
    
    func startHybridMode() async {
        // Start both BLE and WiFi bridge services
        // Monitor connection quality
        // Automatically switch between transports
    }
}
```

### Phase 3: Advanced Features (Week 5-6)

#### 3.1 Bridge Load Balancing
**File**: `BridgeLoadBalancer.swift` (new file)

```swift
class BridgeLoadBalancer {
    private var bridges: [BridgeEndpoint] = []
    private var connectionPool: [String: WiFiBridgeService] = [:]
    
    func distributeMessage(_ message: MeshMessage) async throws {
        // Load balance across multiple bridges
        // Implement failover logic
        // Monitor bridge health
    }
    
    func optimizeConnections() async {
        // Close idle connections
        // Open new connections to healthy bridges
        // Rebalance load
    }
}
```

#### 3.2 Onion Routing (Optional)
**File**: `OnionRoutingService.swift` (new file)

```swift
class OnionRoutingService {
    private let encryptionService: EncryptionService
    
    func createOnionMessage(_ message: MeshMessage, path: [BridgeEndpoint]) async throws -> Data {
        // Layer encryption for each hop
        // Create routing headers
        // Implement forward secrecy
    }
    
    func unwrapOnionLayer(_ data: Data) async throws -> (MeshMessage?, Bool) {
        // Decrypt outer layer
        // Return message if final destination, otherwise forward
    }
}
```

### Phase 4: Security & Privacy Enhancements (Week 7-8)

#### 4.1 Bridge Authentication
**File**: `BridgeAuthService.swift` (new file)

```swift
class BridgeAuthService {
    private let encryptionService: EncryptionService
    
    func generateSessionToken() -> String {
        // Create ephemeral session token
        // No user identity information
    }
    
    func authenticateWithBridge(_ endpoint: BridgeEndpoint) async throws -> String {
        // Perform challenge-response authentication
        // Establish encrypted session
    }
}
```

#### 4.2 Traffic Analysis Resistance
**File**: `TrafficObfuscationService.swift` (new file)

```swift
class TrafficObfuscationService {
    func generateCoverTraffic() async {
        // Send dummy messages to confuse traffic analysis
        // Vary message timing and size
    }
    
    func obfuscateMessageTiming() async {
        // Add random delays
        // Batch messages
        // Implement traffic shaping
    }
}
```

## Technical Specifications

### Bridge Protocol
```
Bridge Message Format:
[Header: 8 bytes]
[SessionToken: 32 bytes]
[EncryptedPayload: Variable]
[Signature: 64 bytes]

Header:
- Version: 1 byte
- MessageType: 1 byte (DATA, HEARTBEAT, CONTROL)
- TTL: 1 byte
- Flags: 1 byte
- PayloadLength: 4 bytes

Message Types:
- DATA: Encrypted mesh message
- HEARTBEAT: Keep-alive ping
- CONTROL: Bridge management commands
```

### Cloudflare Durable Object Schema
```typescript
// State stored in Durable Object
interface SessionData {
  websocket: WebSocket;
  lastSeen: number;
  messageCount: number;
  region: string;
}

interface MessageBuffer {
  messages: BufferedMessage[];
  expiryTime: number;
}

interface BridgeStats {
  totalMessages: number;
  activeConnections: number;
  uptime: number;
  messagesPerSecond: number;
}

// Runtime state (not persisted)
class BridgeRelay {
  private sessions: Map<string, WebSocket>;
  private messageBuffer: Map<string, BufferedMessage[]>;
  private stats: BridgeStats;
}
```

### Bridge Deployment Configuration
```yaml
# wrangler.toml for Cloudflare deployment
name = "bitchat-bridge"
main = "bridge-worker.js"
compatibility_date = "2024-01-01"

[durable_objects]
bindings = [
  { name = "BRIDGE_RELAY", class_name = "BridgeRelay" }
]

[[durable_objects.migrations]]
tag = "v1"
new_classes = ["BridgeRelay"]

[env.production]
route = "bridge.bitchat.app/*"
```

## Integration with Existing Code

### Modified Files

#### 1. `ChatViewModel.swift`
```swift
// Add bridge service integration
@Published var bridgeService: WiFiBridgeService?
@Published var isUsingBridge = false

// Modified message sending
func sendMessage(_ content: String) async {
    let message = createMessage(content)
    
    // Try BLE first, fallback to bridge
    do {
        try await meshService.sendMessage(message)
    } catch {
        if let bridge = bridgeService {
            try await bridge.sendMessage(message)
        }
    }
}
```

#### 2. `BluetoothMeshService.swift`
```swift
// Add bridge integration callbacks
weak var bridgeService: WiFiBridgeService?

func handleReceivedMessage(_ message: MeshMessage) {
    // Process normally for BLE
    // Forward to bridge if needed for hybrid mode
    
    if message.bridgeMetadata?.transportType == .wifiBridge {
        // Handle bridge-originated messages
    }
}
```

#### 3. `ContentView.swift`
```swift
// Add bridge status indicator
HStack {
    if viewModel.isUsingBridge {
        Image(systemName: "wifi")
            .foregroundColor(.blue)
    }
    
    if viewModel.meshService.isConnected {
        Image(systemName: "dot.radiowaves.left.and.right")
            .foregroundColor(.green)
    }
}
```

## Security Considerations

### Bridge Server Security
1. **Zero Knowledge**: Servers cannot decrypt message content
2. **Ephemeral Sessions**: No persistent user data stored
3. **Rate Limiting**: Prevent abuse and DoS attacks
4. **Geographic Distribution**: Multiple regions for redundancy
5. **Open Source**: Bridge server code publicly auditable

### Client Security
1. **Bridge Verification**: Cryptographic verification of bridge identity
2. **Transport Security**: TLS 1.3 for all bridge connections
3. **Metadata Minimization**: Only necessary routing info transmitted
4. **Automatic Fallback**: Return to BLE-only if bridge compromised
5. **User Control**: Option to disable bridge functionality

### Privacy Protections
1. **No User Registration**: Anonymous bridge access
2. **Session Isolation**: Each session uses unique identifiers
3. **Traffic Obfuscation**: Dummy messages and timing randomization
4. **Optional Onion Routing**: Multi-hop message routing
5. **Bridge Rotation**: Regularly change bridge endpoints

## Deployment Strategy

### Phase 1: Development Bridge
- Single Cloudflare Durable Object instance
- Basic message relay functionality
- Internal testing with small group

### Phase 2: Regional Deployment
- Multiple bridge instances across regions
- Load balancing and failover
- Beta testing with larger group

### Phase 3: Production Deployment
- Full global deployment
- Monitoring and analytics
- Public release

### Phase 4: Decentralization
- Community-run bridge servers
- Bridge discovery protocol
- Tor hidden service bridges

## Testing Strategy

### Unit Tests
- Bridge connection and reconnection
- Message encryption/decryption
- Failover scenarios
- Load balancing algorithms

### Integration Tests
- BLE + WiFi hybrid mode
- Bridge discovery and selection
- End-to-end message delivery
- Security protocol verification

### Performance Tests
- Message latency across bridges
- Connection establishment time
- Battery impact measurement
- Network bandwidth usage

### Security Tests
- Penetration testing of bridge servers
- Traffic analysis resistance
- Cryptographic protocol verification
- Privacy leak detection

## Monitoring & Analytics

### Bridge Server Metrics
- Active connections count
- Message throughput
- Error rates
- Response times
- Geographic distribution

### Client Metrics
- Bridge connection success rate
- Message delivery success rate
- Battery impact
- Network usage
- Fallback frequency

### Privacy-Preserving Analytics
- Aggregate usage statistics only
- No individual user tracking
- Encrypted metrics transmission
- Optional reporting (user consent)

## Cost Estimation

### Cloudflare Costs
- Durable Objects: $0.50 per million requests
- Workers: $0.15 per million requests
- Bandwidth: $0.045 per GB
- Storage: $0.20 per GB-month

### Estimated Monthly Cost (1000 active users)
- Durable Objects: ~$50
- Workers: ~$20
- Bandwidth: ~$30
- Storage: ~$10
- **Total: ~$110/month**

### Scaling Projections
- 10K users: ~$500/month
- 100K users: ~$2,500/month
- 1M users: ~$15,000/month

## Future Enhancements

### Advanced Features
1. **Voice Bridge**: Relay voice messages through bridges
2. **File Bridge**: Transfer files via bridge network
3. **Bridge Mesh**: Bridges form their own mesh network
4. **Incentive System**: Token rewards for bridge operators
5. **Bridge Marketplace**: User-selectable bridge services

### Decentralization
1. **P2P Bridge Discovery**: DHT-based bridge finding
2. **Community Bridges**: User-operated bridge nodes
3. **Blockchain Integration**: Decentralized bridge registry
4. **Reputation System**: Bridge reliability scoring
5. **Federation**: Inter-bridge communication protocols

## Implementation Timeline

### Week 1-2: Core Infrastructure
- [ ] Cloudflare Durable Object setup
- [ ] Basic WebSocket bridge server
- [ ] Swift bridge service foundation
- [ ] Message protocol extensions

### Week 3-4: Integration & Discovery
- [ ] Bridge discovery service
- [ ] Hybrid transport manager
- [ ] BLE + WiFi integration
- [ ] Automatic failover logic

### Week 5-6: Advanced Features
- [ ] Load balancing implementation
- [ ] Onion routing (optional)
- [ ] Connection pooling
- [ ] Performance optimization

### Week 7-8: Security & Privacy
- [ ] Bridge authentication
- [ ] Traffic obfuscation
- [ ] Security audit
- [ ] Privacy verification

### Week 9-10: Testing & Deployment
- [ ] Comprehensive testing
- [ ] Performance benchmarking
- [ ] Production deployment
- [ ] Documentation and guides

## Conclusion

This WiFi bridge implementation will extend bitchat's reach while maintaining its core privacy and security principles. The bridge serves as a relay for encrypted messages between isolated mesh networks, enabling global communication without compromising user privacy or the decentralized nature of the system.

The implementation maintains backward compatibility, ensures optional usage, and provides multiple layers of security and privacy protection. Users can seamlessly communicate across the globe while retaining the ability to operate in completely offline mode when needed.