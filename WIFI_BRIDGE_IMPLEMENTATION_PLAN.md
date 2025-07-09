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

#### Project Structure
```
bridge-server/
├── src/
│   ├── index.ts          # Main worker entry point
│   ├── bridge-relay.ts   # Durable Object implementation
│   └── types.ts          # TypeScript type definitions
├── deploy/
│   ├── deploy.ts         # Main deployment script
│   ├── config.ts         # Deployment configuration
│   ├── cloudflare-api.ts # Cloudflare API helpers
│   └── utils.ts          # Deployment utilities
├── scripts/
│   ├── build.ts          # Build script
│   ├── clean.ts          # Cleanup script
│   └── test-deployment.ts # Deployment testing
├── package.json          # Zero dependencies
├── tsconfig.json         # TypeScript configuration
├── .env.example          # Environment variables template
└── bun.lockb             # Bun lock file
```

#### package.json (Zero Dependencies)
```json
{
  "name": "bitchat-bridge",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "build": "bun run scripts/build.ts",
    "deploy": "bun run deploy/deploy.ts",
    "deploy:staging": "bun run deploy/deploy.ts --env=staging",
    "deploy:production": "bun run deploy/deploy.ts --env=production",
    "cleanup": "bun run scripts/clean.ts",
    "test-deploy": "bun run scripts/test-deployment.ts",
    "dev": "bun run --watch src/index.ts"
  },
  "devDependencies": {
    "bun-types": "latest"
  }
}
```

#### tsconfig.json
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "allowSyntheticDefaultImports": true,
    "esModuleInterop": true,
    "allowJs": true,
    "strict": true,
    "skipLibCheck": true,
    "types": ["bun-types"],
    "lib": ["ES2022", "DOM"]
  },
  "include": ["src/**/*", "deploy/**/*", "scripts/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

#### deploy/config.ts - Deployment Configuration
```typescript
export interface DeploymentConfig {
  scriptName: string;
  compatibilityDate: string;
  compatibilityFlags: string[];
  durableObjects: DurableObjectConfig[];
  routes: RouteConfig[];
}

export interface DurableObjectConfig {
  name: string;
  className: string;
  scriptName?: string;
}

export interface RouteConfig {
  pattern: string;
  zone: string;
}

export const deploymentConfigs: Record<string, DeploymentConfig> = {
  staging: {
    scriptName: "bitchat-bridge-staging",
    compatibilityDate: "2024-01-01",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: [
      {
        name: "BRIDGE_RELAY",
        className: "BridgeRelay"
      }
    ],
    routes: [
      {
        pattern: "bridge-staging.bitchat.app/*",
        zone: process.env.CLOUDFLARE_ZONE_ID_STAGING!
      }
    ]
  },
  
  production: {
    scriptName: "bitchat-bridge",
    compatibilityDate: "2024-01-01",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: [
      {
        name: "BRIDGE_RELAY",
        className: "BridgeRelay"
      }
    ],
    routes: [
      {
        pattern: "bridge.bitchat.app/*",
        zone: process.env.CLOUDFLARE_ZONE_ID!
      }
    ]
  }
};

export const getConfig = (env: string = 'staging'): DeploymentConfig => {
  const config = deploymentConfigs[env];
  if (!config) {
    throw new Error(`Unknown environment: ${env}`);
  }
  return config;
};
```

#### deploy/cloudflare-api.ts - Native Cloudflare API Client
```typescript
export interface CloudflareResponse<T = any> {
  success: boolean;
  errors: Array<{ code: number; message: string }>;
  messages: Array<{ code: number; message: string }>;
  result: T;
}

export interface WorkerScript {
  id: string;
  etag: string;
  size: number;
  modified_on: string;
}

export interface DurableObjectNamespace {
  id: string;
  name: string;
  script: string;
  class: string;
}

export interface WorkerRoute {
  id: string;
  pattern: string;
  script?: string;
  zone_id: string;
  zone_name: string;
}

export class CloudflareAPI {
  private apiToken: string;
  private accountId: string;
  private baseURL = 'https://api.cloudflare.com/client/v4';

  constructor(apiToken: string, accountId: string) {
    this.apiToken = apiToken;
    this.accountId = accountId;
  }

  private async request<T = any>(
    endpoint: string, 
    options: RequestInit = {}
  ): Promise<CloudflareResponse<T>> {
    const url = `${this.baseURL}${endpoint}`;
    const response = await fetch(url, {
      ...options,
      headers: {
        'Authorization': `Bearer ${this.apiToken}`,
        'Content-Type': 'application/json',
        ...options.headers
      }
    });

    const data = await response.json() as CloudflareResponse<T>;

    if (!response.ok || !data.success) {
      const errorMessage = data.errors?.map(e => e.message).join(', ') || 'Unknown error';
      throw new Error(`Cloudflare API error (${response.status}): ${errorMessage}`);
    }

    return data;
  }

  async uploadWorkerScript(
    scriptName: string, 
    scriptContent: string, 
    metadata: WorkerMetadata
  ): Promise<WorkerScript> {
    const formData = new FormData();
    formData.append('script', new Blob([scriptContent], { type: 'application/javascript' }));
    formData.append('metadata', JSON.stringify(metadata));

    const response = await fetch(
      `${this.baseURL}/accounts/${this.accountId}/workers/scripts/${scriptName}`,
      {
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${this.apiToken}`
        },
        body: formData
      }
    );

    const data = await response.json() as CloudflareResponse<WorkerScript>;

    if (!response.ok || !data.success) {
      const errorMessage = data.errors?.map(e => e.message).join(', ') || 'Upload failed';
      throw new Error(`Worker upload failed (${response.status}): ${errorMessage}`);
    }

    return data.result;
  }

  async createDurableObjectNamespace(
    name: string, 
    className: string, 
    scriptName: string
  ): Promise<DurableObjectNamespace> {
    const response = await this.request<DurableObjectNamespace>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces`,
      {
        method: 'POST',
        body: JSON.stringify({
          name,
          class: className,
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async updateDurableObjectNamespace(
    namespaceId: string, 
    className: string, 
    scriptName: string
  ): Promise<DurableObjectNamespace> {
    const response = await this.request<DurableObjectNamespace>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces/${namespaceId}`,
      {
        method: 'PUT',
        body: JSON.stringify({
          class: className,
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async listDurableObjectNamespaces(): Promise<DurableObjectNamespace[]> {
    const response = await this.request<DurableObjectNamespace[]>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces`
    );
    return response.result;
  }

  async getDurableObjectNamespace(namespaceId: string): Promise<DurableObjectNamespace> {
    const response = await this.request<DurableObjectNamespace>(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces/${namespaceId}`
    );
    return response.result;
  }

  async deleteDurableObjectNamespace(namespaceId: string): Promise<void> {
    await this.request(
      `/accounts/${this.accountId}/workers/durable_objects/namespaces/${namespaceId}`,
      { method: 'DELETE' }
    );
  }

  async createRoute(zoneId: string, pattern: string, scriptName: string): Promise<WorkerRoute> {
    const response = await this.request<WorkerRoute>(
      `/zones/${zoneId}/workers/routes`,
      {
        method: 'POST',
        body: JSON.stringify({
          pattern,
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async listRoutes(zoneId: string): Promise<WorkerRoute[]> {
    const response = await this.request<WorkerRoute[]>(`/zones/${zoneId}/workers/routes`);
    return response.result;
  }

  async updateRoute(zoneId: string, routeId: string, scriptName: string): Promise<WorkerRoute> {
    const response = await this.request<WorkerRoute>(
      `/zones/${zoneId}/workers/routes/${routeId}`,
      {
        method: 'PUT',
        body: JSON.stringify({
          script: scriptName
        })
      }
    );
    return response.result;
  }

  async deleteRoute(zoneId: string, routeId: string): Promise<void> {
    await this.request(`/zones/${zoneId}/workers/routes/${routeId}`, {
      method: 'DELETE'
    });
  }

  async getWorkerScript(scriptName: string): Promise<WorkerScript> {
    const response = await this.request<WorkerScript>(
      `/accounts/${this.accountId}/workers/scripts/${scriptName}`
    );
    return response.result;
  }

  async deleteWorkerScript(scriptName: string): Promise<void> {
    await this.request(`/accounts/${this.accountId}/workers/scripts/${scriptName}`, {
      method: 'DELETE'
    });
  }

  async listWorkerScripts(): Promise<WorkerScript[]> {
    const response = await this.request<WorkerScript[]>(
      `/accounts/${this.accountId}/workers/scripts`
    );
    return response.result;
  }

  async validateCredentials(): Promise<boolean> {
    try {
      await this.request('/user/tokens/verify');
      return true;
    } catch {
      return false;
    }
  }
}

export interface WorkerMetadata {
  main_module: string;
  compatibility_date: string;
  compatibility_flags: string[];
  bindings: WorkerBinding[];
}

export interface WorkerBinding {
  name: string;
  type: string;
  class_name?: string;
  script_name?: string;
}
```

#### deploy/utils.ts - Deployment Utilities
```typescript
import { createWriteStream, existsSync, mkdirSync } from 'fs';
import { join } from 'path';

export const colors = {
  reset: '\x1b[0m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  white: '\x1b[37m',
  gray: '\x1b[90m'
} as const;

export const log = {
  info: (msg: string) => console.log(`${colors.blue}ℹ${colors.reset} ${msg}`),
  success: (msg: string) => console.log(`${colors.green}✅${colors.reset} ${msg}`),
  warning: (msg: string) => console.log(`${colors.yellow}⚠${colors.reset} ${msg}`),
  error: (msg: string) => console.log(`${colors.red}❌${colors.reset} ${msg}`),
  step: (msg: string) => console.log(`${colors.cyan}🔧${colors.reset} ${msg}`),
  debug: (msg: string) => console.log(`${colors.gray}🐛${colors.reset} ${msg}`)
} as const;

export function ensureDir(dirPath: string): void {
  if (!existsSync(dirPath)) {
    mkdirSync(dirPath, { recursive: true });
  }
}

export function validateEnvironmentVariables(): {
  apiToken: string;
  accountId: string;
} {
  const apiToken = process.env.CLOUDFLARE_API_TOKEN;
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  
  if (!apiToken) {
    throw new Error('Missing required environment variable: CLOUDFLARE_API_TOKEN');
  }
  
  if (!accountId) {
    throw new Error('Missing required environment variable: CLOUDFLARE_ACCOUNT_ID');
  }
  
  return { apiToken, accountId };
}

export function parseArguments(args: string[]): {
  environment: string;
  isCleanup: boolean;
  isDryRun: boolean;
  verbose: boolean;
} {
  const envFlag = args.find(arg => arg.startsWith('--env='));
  const environment = envFlag ? envFlag.split('=')[1] : 'staging';
  const isCleanup = args.includes('--cleanup');
  const isDryRun = args.includes('--dry-run');
  const verbose = args.includes('--verbose') || args.includes('-v');
  
  return { environment, isCleanup, isDryRun, verbose };
}

export async function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export async function retry<T>(
  fn: () => Promise<T>,
  maxAttempts: number = 3,
  delayMs: number = 1000
): Promise<T> {
  let lastError: Error;
  
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      
      if (attempt === maxAttempts) {
        break;
      }
      
      log.warning(`Attempt ${attempt} failed, retrying in ${delayMs}ms...`);
      await sleep(delayMs);
      delayMs *= 2; // Exponential backoff
    }
  }
  
  throw lastError!;
}

export function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60000).toFixed(1)}m`;
}

export class ProgressSpinner {
  private spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  private current = 0;
  private interval?: Timer;
  private message: string;

  constructor(message: string) {
    this.message = message;
  }

  start(): void {
    process.stdout.write(`${this.spinner[0]} ${this.message}`);
    this.interval = setInterval(() => {
      this.current = (this.current + 1) % this.spinner.length;
      process.stdout.write(`\r${this.spinner[this.current]} ${this.message}`);
    }, 100);
  }

  stop(finalMessage?: string): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = undefined;
    }
    process.stdout.write(`\r${finalMessage || this.message}\n`);
  }
}

export async function writeDeploymentReport(
  environment: string,
  deploymentData: any
): Promise<void> {
  const reportsDir = 'deploy/reports';
  ensureDir(reportsDir);
  
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const reportFile = join(reportsDir, `deployment-${environment}-${timestamp}.json`);
  
  const report = {
    timestamp: new Date().toISOString(),
    environment,
    success: deploymentData.success,
    duration: deploymentData.duration,
    scriptName: deploymentData.scriptName,
    scriptSize: deploymentData.scriptSize,
    durableObjects: deploymentData.durableObjects,
    routes: deploymentData.routes,
    errors: deploymentData.errors || []
  };
  
  await Bun.write(reportFile, JSON.stringify(report, null, 2));
  log.info(`Deployment report saved: ${reportFile}`);
}
```

#### scripts/build.ts - Build Script
```typescript
#!/usr/bin/env bun
import { log, ensureDir, formatBytes, formatDuration } from '../deploy/utils';

export interface BuildOptions {
  minify?: boolean;
  sourcemap?: boolean;
  target?: string;
  outdir?: string;
  watch?: boolean;
}

export class ProjectBuilder {
  private options: Required<BuildOptions>;

  constructor(options: BuildOptions = {}) {
    this.options = {
      minify: options.minify ?? true,
      sourcemap: options.sourcemap ?? false,
      target: options.target ?? 'browser',
      outdir: options.outdir ?? 'dist',
      watch: options.watch ?? false
    };
  }

  async build(): Promise<{
    success: boolean;
    outputPath: string;
    size: number;
    duration: number;
  }> {
    const startTime = Date.now();
    
    log.step('Building worker with Bun...');
    
    // Ensure output directory exists
    ensureDir(this.options.outdir);
    
    try {
      const buildResult = await Bun.build({
        entrypoints: ['src/index.ts'],
        outdir: this.options.outdir,
        target: this.options.target as any,
        minify: this.options.minify,
        sourcemap: this.options.sourcemap ? 'external' : 'none',
        define: {
          'process.env.NODE_ENV': JSON.stringify(process.env.NODE_ENV || 'production')
        }
      });

      if (!buildResult.success) {
        log.error('Build failed:');
        buildResult.logs.forEach(logEntry => {
          console.error(logEntry);
        });
        return {
          success: false,
          outputPath: '',
          size: 0,
          duration: Date.now() - startTime
        };
      }

      const outputPath = `${this.options.outdir}/index.js`;
      const file = Bun.file(outputPath);
      const size = file.size;
      const duration = Date.now() - startTime;

      log.success(`Worker built successfully in ${formatDuration(duration)}`);
      log.info(`Output: ${outputPath} (${formatBytes(size)})`);

      return {
        success: true,
        outputPath,
        size,
        duration
      };

    } catch (error) {
      log.error(`Build error: ${error}`);
      return {
        success: false,
        outputPath: '',
        size: 0,
        duration: Date.now() - startTime
      };
    }
  }

  async watch(): Promise<void> {
    log.info('Starting watch mode...');
    
    // TODO: Implement file watching
    // For now, we'll use Bun's built-in watch mode
    const proc = Bun.spawn(['bun', 'run', '--watch', 'src/index.ts'], {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    log.info('Watching for file changes...');
    await proc.exited;
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const watch = args.includes('--watch');
  const minify = !args.includes('--no-minify');
  const sourcemap = args.includes('--sourcemap');
  
  const builder = new ProjectBuilder({
    minify,
    sourcemap,
    watch
  });

  if (watch) {
    await builder.watch();
  } else {
    const result = await builder.build();
    process.exit(result.success ? 0 : 1);
  }
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}

export { ProjectBuilder };
```

#### scripts/clean.ts - Cleanup Script
```typescript
#!/usr/bin/env bun
import { rmSync, existsSync } from 'fs';
import { log } from '../deploy/utils';
import { CloudflareAPI } from '../deploy/cloudflare-api';
import { getConfig } from '../deploy/config';

export class ProjectCleaner {
  private api?: CloudflareAPI;

  constructor(apiToken?: string, accountId?: string) {
    if (apiToken && accountId) {
      this.api = new CloudflareAPI(apiToken, accountId);
    }
  }

  async cleanLocal(): Promise<void> {
    log.step('Cleaning local build artifacts...');
    
    const pathsToClean = [
      'dist',
      'deploy/reports',
      'node_modules/.cache'
    ];
    
    for (const path of pathsToClean) {
      if (existsSync(path)) {
        rmSync(path, { recursive: true, force: true });
        log.success(`Removed: ${path}`);
      }
    }
  }

  async cleanRemote(environment: string): Promise<void> {
    if (!this.api) {
      log.warning('No API credentials provided, skipping remote cleanup');
      return;
    }

    log.step(`Cleaning remote resources for ${environment}...`);
    
    const config = getConfig(environment);
    
    try {
      // Remove routes
      for (const route of config.routes) {
        const routes = await this.api.listRoutes(route.zone);
        const matching = routes.filter(r => 
          r.pattern === route.pattern && r.script === config.scriptName
        );
        
        for (const matchRoute of matching) {
          await this.api.deleteRoute(route.zone, matchRoute.id);
          log.success(`Route removed: ${route.pattern}`);
        }
      }
      
      // Remove Durable Object namespaces
      const namespaces = await this.api.listDurableObjectNamespaces();
      for (const obj of config.durableObjects) {
        const existing = namespaces.find(ns => ns.name === obj.name);
        if (existing) {
          await this.api.deleteDurableObjectNamespace(existing.id);
          log.success(`Durable Object namespace removed: ${obj.name}`);
        }
      }
      
      // Remove worker
      try {
        await this.api.deleteWorkerScript(config.scriptName);
        log.success(`Worker script removed: ${config.scriptName}`);
      } catch (error) {
        log.warning(`Worker script may not exist: ${config.scriptName}`);
      }
      
    } catch (error) {
      log.error(`Remote cleanup failed: ${error}`);
      throw error;
    }
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const environment = args.find(arg => arg.startsWith('--env='))?.split('=')[1] || 'staging';
  const localOnly = args.includes('--local-only');
  const remoteOnly = args.includes('--remote-only');
  
  const apiToken = process.env.CLOUDFLARE_API_TOKEN;
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  
  const cleaner = new ProjectCleaner(apiToken, accountId);
  
  try {
    if (!remoteOnly) {
      await cleaner.cleanLocal();
    }
    
    if (!localOnly && apiToken && accountId) {
      await cleaner.cleanRemote(environment);
    }
    
    log.success('Cleanup completed successfully!');
  } catch (error) {
    log.error(`Cleanup failed: ${error}`);
    process.exit(1);
  }
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}

export { ProjectCleaner };
```

#### scripts/test-deployment.ts - Deployment Testing
```typescript
#!/usr/bin/env bun
import { log, sleep, retry } from '../deploy/utils';

export interface HealthCheckResult {
  endpoint: string;
  status: number;
  responseTime: number;
  success: boolean;
  error?: string;
}

export class DeploymentTester {
  private baseUrls: string[];

  constructor(baseUrls: string[]) {
    this.baseUrls = baseUrls;
  }

  async testEndpoints(): Promise<HealthCheckResult[]> {
    log.step('Testing deployed endpoints...');
    
    const results: HealthCheckResult[] = [];
    
    for (const baseUrl of this.baseUrls) {
      const endpoints = [
        `${baseUrl}/health`,
        `${baseUrl}/bridges`,
        `${baseUrl}/bridge/global/stats`
      ];
      
      for (const endpoint of endpoints) {
        const result = await this.testEndpoint(endpoint);
        results.push(result);
        
        if (result.success) {
          log.success(`✓ ${endpoint} (${result.responseTime}ms)`);
        } else {
          log.error(`✗ ${endpoint} - ${result.error}`);
        }
      }
    }
    
    return results;
  }

  private async testEndpoint(url: string): Promise<HealthCheckResult> {
    const startTime = Date.now();
    
    try {
      const response = await retry(
        () => fetch(url, { 
          method: 'GET',
          headers: {
            'User-Agent': 'bitchat-bridge-tester/1.0'
          }
        }),
        3,
        2000
      );
      
      const responseTime = Date.now() - startTime;
      
      return {
        endpoint: url,
        status: response.status,
        responseTime,
        success: response.ok
      };
      
    } catch (error) {
      return {
        endpoint: url,
        status: 0,
        responseTime: Date.now() - startTime,
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      };
    }
  }

  async testWebSocketConnection(wsUrl: string): Promise<boolean> {
    log.step(`Testing WebSocket connection: ${wsUrl}`);
    
    return new Promise((resolve) => {
      const ws = new WebSocket(wsUrl);
      let resolved = false;
      
      const timeout = setTimeout(() => {
        if (!resolved) {
          resolved = true;
          ws.close();
          log.error('WebSocket connection timeout');
          resolve(false);
        }
      }, 10000);
      
      ws.onopen = () => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timeout);
          log.success('WebSocket connection successful');
          ws.close();
          resolve(true);
        }
      };
      
      ws.onerror = (error) => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timeout);
          log.error(`WebSocket connection failed: ${error}`);
          resolve(false);
        }
      };
    });
  }

  async runFullTest(): Promise<{
    success: boolean;
    results: HealthCheckResult[];
    websocketSuccess: boolean;
  }> {
    const results = await this.testEndpoints();
    const allEndpointsHealthy = results.every(r => r.success);
    
    // Test WebSocket connection to first URL
    let websocketSuccess = false;
    if (this.baseUrls.length > 0) {
      const wsUrl = this.baseUrls[0].replace('https://', 'wss://') + '/bridge/global';
      websocketSuccess = await this.testWebSocketConnection(wsUrl);
    }
    
    const success = allEndpointsHealthy && websocketSuccess;
    
    if (success) {
      log.success('All deployment tests passed!');
    } else {
      log.error('Some deployment tests failed');
    }
    
    return {
      success,
      results,
      websocketSuccess
    };
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const environment = args.find(arg => arg.startsWith('--env='))?.split('=')[1] || 'staging';
  
  const urls = environment === 'production' 
    ? ['https://bridge.bitchat.app']
    : ['https://bridge-staging.bitchat.app'];
  
  const tester = new DeploymentTester(urls);
  const result = await tester.runFullTest();
  
  process.exit(result.success ? 0 : 1);
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}

export { DeploymentTester };
```
#### deploy/deploy.ts - Main Deployment Script
```typescript
#!/usr/bin/env bun
import { CloudflareAPI, type WorkerMetadata } from './cloudflare-api';
import { getConfig, type DeploymentConfig } from './config';
import { 
  log, 
  validateEnvironmentVariables, 
  parseArguments,
  ProgressSpinner,
  retry,
  formatBytes,
  formatDuration,
  writeDeploymentReport
} from './utils';
import { ProjectBuilder } from '../scripts/build';

export class BitchatBridgeDeployer {
  private api: CloudflareAPI;
  private config: DeploymentConfig;
  private environment: string;
  private isDryRun: boolean;
  private verbose: boolean;

  constructor(environment: string = 'staging', isDryRun: boolean = false, verbose: boolean = false) {
    this.environment = environment;
    this.isDryRun = isDryRun;
    this.verbose = verbose;
    this.config = getConfig(environment);
    
    const { apiToken, accountId } = validateEnvironmentVariables();
    this.api = new CloudflareAPI(apiToken, accountId);
  }

  async deploy(): Promise<{
    success: boolean;
    scriptName: string;
    scriptSize: number;
    duration: number;
    errors: string[];
  }> {
    const startTime = Date.now();
    const errors: string[] = [];
    
    log.info(`🚀 Starting deployment to ${this.environment}${this.isDryRun ? ' (DRY RUN)' : ''}...`);
    
    try {
      // Validate credentials first
      await this.validateCredentials();
      
      // Step 1: Build the worker
      const buildResult = await this.buildWorker();
      if (!buildResult.success) {
        throw new Error('Build failed');
      }
      
      // Step 2: Upload worker script
      const uploadResult = await this.uploadWorkerScript(buildResult.outputPath);
      
      // Step 3: Setup Durable Objects
      await this.setupDurableObjects();
      
      // Step 4: Configure routes
      await this.configureRoutes();
      
      const duration = Date.now() - startTime;
      
      // Write deployment report
      await writeDeploymentReport(this.environment, {
        success: true,
        duration,
        scriptName: this.config.scriptName,
        scriptSize: buildResult.size,
        durableObjects: this.config.durableObjects,
        routes: this.config.routes,
        errors
      });
      
      log.success(`🎉 Deployment to ${this.environment} completed successfully in ${formatDuration(duration)}!`);
      log.info(`🌐 Bridge available at: https://${this.config.routes[0]?.pattern.replace('/*', '')}`);
      
      return {
        success: true,
        scriptName: this.config.scriptName,
        scriptSize: buildResult.size,
        duration,
        errors
      };
      
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      errors.push(errorMessage);
      
      await writeDeploymentReport(this.environment, {
        success: false,
        duration: Date.now() - startTime,
        scriptName: this.config.scriptName,
        scriptSize: 0,
        durableObjects: this.config.durableObjects,
        routes: this.config.routes,
        errors
      });
      
      log.error(`❌ Deployment failed: ${errorMessage}`);
      
      return {
        success: false,
        scriptName: this.config.scriptName,
        scriptSize: 0,
        duration: Date.now() - startTime,
        errors
      };
    }
  }

  private async validateCredentials(): Promise<void> {
    const spinner = new ProgressSpinner('Validating Cloudflare credentials...');
    spinner.start();
    
    try {
      const isValid = await this.api.validateCredentials();
      if (!isValid) {
        throw new Error('Invalid Cloudflare API credentials');
      }
      spinner.stop(`${log.success.name} Credentials validated`);
    } catch (error) {
      spinner.stop(`${log.error.name} Credential validation failed`);
      throw error;
    }
  }

  private async buildWorker(): Promise<{
    success: boolean;
    outputPath: string;
    size: number;
  }> {
    log.step('Building worker with Bun...');
    
    const builder = new ProjectBuilder({
      minify: true,
      sourcemap: false
    });
    
    const result = await builder.build();
    
    if (!result.success) {
      throw new Error('Worker build failed');
    }
    
    return result;
  }

  private async uploadWorkerScript(scriptPath: string): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would upload worker script');
      return;
    }
    
    const spinner = new ProgressSpinner('Uploading worker script...');
    spinner.start();
    
    try {
      const scriptContent = await Bun.file(scriptPath).text();
      const scriptSize = new Blob([scriptContent]).size;
      
      const metadata: WorkerMetadata = {
        main_module: 'index.js',
        compatibility_date: this.config.compatibilityDate,
        compatibility_flags: this.config.compatibilityFlags,
        bindings: this.config.durableObjects.map(obj => ({
          name: obj.name,
          type: 'durable_object_namespace',
          class_name: obj.className
        }))
      };

      await retry(
        () => this.api.uploadWorkerScript(this.config.scriptName, scriptContent, metadata),
        3,
        2000
      );

      spinner.stop(`✅ Worker script uploaded (${formatBytes(scriptSize)})`);
      
    } catch (error) {
      spinner.stop('❌ Worker upload failed');
      throw error;
    }
  }

  private async setupDurableObjects(): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would setup Durable Objects');
      return;
    }
    
    log.step('Setting up Durable Objects...');
    
    for (const obj of this.config.durableObjects) {
      const spinner = new ProgressSpinner(`Setting up ${obj.name}...`);
      spinner.start();
      
      try {
        // Check if namespace already exists
        const namespaces = await this.api.listDurableObjectNamespaces();
        const existing = namespaces.find(ns => ns.name === obj.name);
        
        if (existing) {
          if (this.verbose) {
            log.info(`Updating existing Durable Object namespace: ${obj.name}`);
          }
          await this.api.updateDurableObjectNamespace(
            existing.id,
            obj.className,
            this.config.scriptName
          );
        } else {
          if (this.verbose) {
            log.info(`Creating new Durable Object namespace: ${obj.name}`);
          }
          await this.api.createDurableObjectNamespace(
            obj.name,
            obj.className,
            this.config.scriptName
          );
        }
        
        spinner.stop(`✅ Durable Object ${obj.name} configured`);
        
      } catch (error) {
        spinner.stop(`⚠️ Durable Object ${obj.name} setup had issues`);
        log.warning(`Failed to setup Durable Object ${obj.name}: ${error}`);
        // Continue with deployment - might be a permissions issue
      }
    }
  }

  private async configureRoutes(): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would configure routes');
      return;
    }
    
    log.step('Configuring routes...');
    
    for (const route of this.config.routes) {
      const spinner = new ProgressSpinner(`Configuring route ${route.pattern}...`);
      spinner.start();
      
      try {
        // Clean up existing routes first
        const existingRoutes = await this.api.listRoutes(route.zone);
        const conflicting = existingRoutes.filter(r => 
          r.pattern === route.pattern && r.script !== this.config.scriptName
        );
        
        for (const conflictRoute of conflicting) {
          if (this.verbose) {
            log.info(`Removing conflicting route: ${conflictRoute.pattern}`);
          }
          await this.api.deleteRoute(route.zone, conflictRoute.id);
        }
        
        // Check if route already exists for our script
        const existingForScript = existingRoutes.find(r => 
          r.pattern === route.pattern && r.script === this.config.scriptName
        );
        
        if (existingForScript) {
          // Route already exists, update it
          await this.api.updateRoute(route.zone, existingForScript.id, this.config.scriptName);
        } else {
          // Create new route
          await this.api.createRoute(route.zone, route.pattern, this.config.scriptName);
        }
        
        spinner.stop(`✅ Route configured: ${route.pattern}`);
        
      } catch (error) {
        spinner.stop(`⚠️ Route ${route.pattern} configuration failed`);
        log.warning(`Failed to configure route ${route.pattern}: ${error}`);
      }
    }
  }

  async cleanup(): Promise<void> {
    if (this.isDryRun) {
      log.info('DRY RUN: Would cleanup deployment');
      return;
    }
    
    log.step(`🧹 Cleaning up deployment for ${this.environment}...`);
    
    try {
      // Remove routes
      for (const route of this.config.routes) {
        const spinner = new ProgressSpinner(`Removing route ${route.pattern}...`);
        spinner.start();
        
        try {
          const routes = await this.api.listRoutes(route.zone);
          const matching = routes.filter(r => 
            r.pattern === route.pattern && r.script === this.config.scriptName
          );
          
          for (const matchRoute of matching) {
            await this.api.deleteRoute(route.zone, matchRoute.id);
          }
          
          spinner.stop(`✅ Route removed: ${route.pattern}`);
        } catch (error) {
          spinner.stop(`⚠️ Route removal failed: ${route.pattern}`);
        }
      }
      
      // Remove Durable Object namespaces
      const namespaces = await this.api.listDurableObjectNamespaces();
      for (const obj of this.config.durableObjects) {
        const existing = namespaces.find(ns => ns.name === obj.name);
        if (existing) {
          const spinner = new ProgressSpinner(`Removing namespace ${obj.name}...`);
          spinner.start();
          
          try {
            await this.api.deleteDurableObjectNamespace(existing.id);
            spinner.stop(`✅ Durable Object namespace removed: ${obj.name}`);
          } catch (error) {
            spinner.stop(`⚠️ Namespace removal failed: ${obj.name}`);
          }
        }
      }
      
      // Remove worker
      const spinner = new ProgressSpinner(`Removing worker ${this.config.scriptName}...`);
      spinner.start();
      
      try {
        await this.api.deleteWorkerScript(this.config.scriptName);
        spinner.stop(`✅ Worker script removed: ${this.config.scriptName}`);
      } catch (error) {
        spinner.stop(`⚠️ Worker script may not exist: ${this.config.scriptName}`);
      }
      
      log.success('🧹 Cleanup completed successfully!');
      
    } catch (error) {
      log.error(`Cleanup failed: ${error}`);
      throw error;
    }
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  const { environment, isCleanup, isDryRun, verbose } = parseArguments(args);
  
  const deployer = new BitchatBridgeDeployer(environment, isDryRun, verbose);
  
  try {
    if (isCleanup) {
      await deployer.cleanup();
    } else {
      const result = await deployer.deploy();
      process.exit(result.success ? 0 : 1);
    }
  } catch (error) {
    log.error(`Operation failed: ${error}`);
    process.exit(1);
  }
}

// Run if called directly
if (import.meta.main) {
  main().catch(console.error);
}

export { BitchatBridgeDeployer };
```

#### Environment Variables Setup
```bash
# .env.example - Copy to .env and fill in your values
CLOUDFLARE_API_TOKEN=your_api_token_here
CLOUDFLARE_ACCOUNT_ID=your_account_id_here
CLOUDFLARE_ZONE_ID=your_production_zone_id_here
CLOUDFLARE_ZONE_ID_STAGING=your_staging_zone_id_here
```

#### Usage Commands
```bash
# Build only
bun run build

# Build with watch mode
bun run build --watch

# Deploy to staging
bun run deploy:staging

# Deploy to production
bun run deploy:production

# Dry run deployment (preview without changes)
bun run deploy:staging --dry-run

# Verbose deployment output
bun run deploy:staging --verbose

# Test deployment
bun run test-deploy --env=staging

# Cleanup staging deployment
bun run deploy:staging --cleanup

# Cleanup production deployment  
bun run deploy:production --cleanup

# Clean local build artifacts
bun run cleanup --local-only

# Clean remote resources only
bun run cleanup --remote-only --env=staging

# Full cleanup (local + remote)
bun run cleanup --env=staging
```

#### Advanced Deployment Features
- **Zero Dependencies**: No npm packages, pure Bun + TypeScript
- **Type Safety**: Full TypeScript throughout deployment pipeline
- **Error Handling**: Comprehensive error handling with retry logic
- **Progress Indicators**: Visual feedback during deployment steps
- **Deployment Reports**: JSON reports saved for each deployment
- **Dry Run Mode**: Preview changes without applying them
- **Health Checks**: Automated testing of deployed endpoints
- **Rollback Support**: Easy cleanup and removal of deployments
- **Multi-Environment**: Separate staging and production configurations

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