// Cloudflare Durable Object implementation for bitchat bridge relay

import type { BridgeMessage, BufferedMessage, BridgeStats } from './types';

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
        ttl: Math.max(0, (payload.ttl || 6) - 1),
        messageId: payload.messageId // Preserve messageId for tracking
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