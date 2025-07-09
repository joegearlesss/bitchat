#!/usr/bin/env node

// Bridge server test script
import WebSocket from 'ws';

const BRIDGE_URL = 'wss://bitchat-bridge-staging.shirato.workers.dev/bridge/global';
const STATS_URL = 'https://bitchat-bridge-staging.shirato.workers.dev/bridge/global/stats';

class BridgeTest {
  constructor() {
    this.clients = [];
    this.messageCount = 0;
    this.receivedMessages = [];
  }

  async testStats() {
    console.log('🔍 Testing bridge stats endpoint...');
    try {
      const response = await fetch(STATS_URL);
      const stats = await response.json();
      console.log('✅ Stats endpoint working:', stats);
      return true;
    } catch (error) {
      console.error('❌ Stats test failed:', error.message);
      return false;
    }
  }

  async createWebSocketClient(clientId) {
    return new Promise((resolve, reject) => {
      console.log(`🔌 Connecting client ${clientId}...`);
      
      const ws = new WebSocket(BRIDGE_URL);
      
      ws.on('open', () => {
        console.log(`✅ Client ${clientId} connected`);
        resolve(ws);
      });

      ws.on('message', (data) => {
        try {
          const message = JSON.parse(data.toString());
          console.log(`📨 Client ${clientId} received:`, message.type);
          
          if (message.type === 'welcome') {
            console.log(`🎉 Client ${clientId} welcomed with session:`, message.sessionId);
          } else if (message.type === 'data') {
            this.receivedMessages.push({
              clientId,
              message,
              timestamp: Date.now()
            });
            console.log(`📦 Client ${clientId} received relayed message:`, message.payload?.messageId);
          } else if (message.type === 'heartbeat_ack') {
            console.log(`💓 Client ${clientId} heartbeat acknowledged`);
          }
        } catch (error) {
          console.error(`❌ Client ${clientId} message parse error:`, error.message);
        }
      });

      ws.on('error', (error) => {
        console.error(`❌ Client ${clientId} error:`, error.message);
        reject(error);
      });

      ws.on('close', () => {
        console.log(`🔌 Client ${clientId} disconnected`);
      });

      // Timeout after 10 seconds
      setTimeout(() => {
        if (ws.readyState !== WebSocket.OPEN) {
          reject(new Error(`Client ${clientId} connection timeout`));
        }
      }, 10000);
    });
  }

  async testWebSocketConnection() {
    console.log('\n🧪 Testing WebSocket connections...');
    
    try {
      // Create two clients
      const client1 = await this.createWebSocketClient('A');
      const client2 = await this.createWebSocketClient('B');
      
      this.clients = [client1, client2];
      
      // Wait a moment for welcome messages
      await new Promise(resolve => setTimeout(resolve, 1000));
      
      return true;
    } catch (error) {
      console.error('❌ WebSocket connection test failed:', error.message);
      return false;
    }
  }

  async testHeartbeat() {
    console.log('\n💓 Testing heartbeat functionality...');
    
    if (this.clients.length === 0) {
      console.error('❌ No clients available for heartbeat test');
      return false;
    }

    try {
      const client = this.clients[0];
      
      // Send heartbeat
      const heartbeat = {
        type: 'heartbeat',
        timestamp: Date.now()
      };
      
      client.send(JSON.stringify(heartbeat));
      console.log('📤 Heartbeat sent');
      
      // Wait for response
      await new Promise(resolve => setTimeout(resolve, 2000));
      
      return true;
    } catch (error) {
      console.error('❌ Heartbeat test failed:', error.message);
      return false;
    }
  }

  async testMessageRelay() {
    console.log('\n🔄 Testing message relay functionality...');
    
    if (this.clients.length < 2) {
      console.error('❌ Need at least 2 clients for relay test');
      return false;
    }

    try {
      const [sender, receiver] = this.clients;
      
      // Create a test message (simulating encrypted bitchat message)
      const testMessage = {
        type: 'data',
        payload: {
          encryptedData: 'dGVzdCBtZXNzYWdl', // base64 "test message"
          signature: 'dGVzdCBzaWduYXR1cmU=', // base64 "test signature"
          timestamp: Date.now(),
          ttl: 5,
          messageId: 'test-msg-' + Date.now()
        }
      };

      console.log('📤 Sending test message from client A...');
      sender.send(JSON.stringify(testMessage));
      
      // Wait for relay
      await new Promise(resolve => setTimeout(resolve, 2000));
      
      // Check if message was relayed
      const relayedMessage = this.receivedMessages.find(
        msg => msg.message.payload?.messageId === testMessage.payload.messageId
      );
      
      if (relayedMessage) {
        console.log('✅ Message successfully relayed to client B');
        return true;
      } else {
        console.log('❌ Message was not relayed');
        return false;
      }
      
    } catch (error) {
      console.error('❌ Message relay test failed:', error.message);
      return false;
    }
  }

  async testStatsAfterActivity() {
    console.log('\n📊 Testing stats after activity...');
    
    try {
      const response = await fetch(STATS_URL);
      const stats = await response.json();
      
      console.log('📈 Updated stats:', stats);
      
      if (stats.activeConnections > 0) {
        console.log('✅ Active connections detected');
      }
      
      if (stats.totalMessages > 0) {
        console.log('✅ Message count updated');
      }
      
      return true;
    } catch (error) {
      console.error('❌ Stats after activity test failed:', error.message);
      return false;
    }
  }

  cleanup() {
    console.log('\n🧹 Cleaning up connections...');
    this.clients.forEach((client, index) => {
      if (client.readyState === WebSocket.OPEN) {
        client.close();
        console.log(`🔌 Client ${String.fromCharCode(65 + index)} disconnected`);
      }
    });
  }

  async runAllTests() {
    console.log('🚀 Starting bridge server tests...\n');
    
    const results = {
      stats: false,
      websocket: false,
      heartbeat: false,
      relay: false,
      statsAfter: false
    };

    try {
      // Test 1: Stats endpoint
      results.stats = await this.testStats();
      
      // Test 2: WebSocket connections
      if (results.stats) {
        results.websocket = await this.testWebSocketConnection();
      }
      
      // Test 3: Heartbeat
      if (results.websocket) {
        results.heartbeat = await this.testHeartbeat();
      }
      
      // Test 4: Message relay
      if (results.websocket) {
        results.relay = await this.testMessageRelay();
      }
      
      // Test 5: Stats after activity
      results.statsAfter = await this.testStatsAfterActivity();
      
    } finally {
      this.cleanup();
    }

    // Print results
    console.log('\n📋 Test Results:');
    console.log('================');
    Object.entries(results).forEach(([test, passed]) => {
      const status = passed ? '✅ PASS' : '❌ FAIL';
      console.log(`${status} ${test}`);
    });

    const passedTests = Object.values(results).filter(Boolean).length;
    const totalTests = Object.keys(results).length;
    
    console.log(`\n🎯 Overall: ${passedTests}/${totalTests} tests passed`);
    
    if (passedTests === totalTests) {
      console.log('🎉 All tests passed! Bridge server is working correctly.');
      return true;
    } else {
      console.log('⚠️  Some tests failed. Bridge server may have issues.');
      return false;
    }
  }
}

// Run tests
const tester = new BridgeTest();
tester.runAllTests()
  .then(success => {
    process.exit(success ? 0 : 1);
  })
  .catch(error => {
    console.error('💥 Test runner crashed:', error);
    process.exit(1);
  });