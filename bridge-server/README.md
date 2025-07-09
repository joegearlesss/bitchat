# bitchat Bridge Server

A zero-knowledge WebSocket relay server for extending bitchat's mesh network across the internet. Built with Cloudflare Durable Objects for global scale and zero-dependency deployment.

## Overview

The bitchat bridge server enables users to connect their local Bluetooth mesh networks across the internet while maintaining complete privacy and security. The server acts as a simple relay - it cannot decrypt messages or identify users.

### Key Features

- **Zero-Knowledge Relay**: Server cannot decrypt message content
- **Global Scale**: Cloudflare's edge network for low latency worldwide
- **Privacy-First**: No user registration, tracking, or data storage
- **Ephemeral Sessions**: Temporary connections with no persistent state
- **Auto-Scaling**: Handles traffic spikes automatically
- **Zero Dependencies**: Pure TypeScript with no external packages

## Architecture

```
┌─────────────────┐    WebSocket    ┌─────────────────┐    WebSocket    ┌─────────────────┐
│   bitchat App   │◄──────────────►│  Bridge Server  │◄──────────────►│   bitchat App   │
│   (Location A)  │                │ (Cloudflare DO) │                │   (Location B)  │
└─────────────────┘                └─────────────────┘                └─────────────────┘
        │                                    │                                    │
        ▼                                    ▼                                    ▼
┌─────────────────┐                ┌─────────────────┐                ┌─────────────────┐
│  Local BLE Mesh │                │  Message Relay  │                │  Local BLE Mesh │
│                 │                │   (Encrypted)   │                │                 │
└─────────────────┘                └─────────────────┘                └─────────────────┘
```

### Message Flow

1. **Client Connection**: bitchat app connects via WebSocket
2. **Message Relay**: Encrypted messages forwarded to all connected clients
3. **TTL Decrement**: Time-to-live reduced to prevent infinite loops
4. **Store-and-Forward**: Brief message buffering for offline clients
5. **Session Cleanup**: Automatic cleanup of stale connections

## Project Structure

```
bridge-server/
├── src/
│   ├── index.ts          # Main Cloudflare Worker entry point
│   ├── bridge-relay.ts   # Durable Object WebSocket relay
│   └── types.ts          # TypeScript type definitions
├── deploy/
│   ├── deploy.ts         # Main deployment script
│   ├── config.ts         # Environment configurations
│   ├── cloudflare-api.ts # Native Cloudflare API client
│   └── utils.ts          # Deployment utilities
├── scripts/
│   ├── build.ts          # Bun-based build script
│   ├── clean.ts          # Cleanup script
│   └── test-deployment.ts # Health check testing
├── dist/                 # Built output (generated)
├── package.json          # Zero dependencies
├── tsconfig.json         # TypeScript configuration
├── .env.example          # Environment variables template
└── README.md            # This file
```

## Quick Start

### Prerequisites

- [Bun](https://bun.sh) runtime
- Cloudflare account with Workers enabled
- Domain configured in Cloudflare (for custom endpoints)

### 1. Environment Setup

```bash
# Copy environment template
cp .env.example .env

# Edit with your Cloudflare credentials
nano .env
```

Required environment variables:
```bash
CLOUDFLARE_API_TOKEN=your_api_token_here
CLOUDFLARE_ACCOUNT_ID=your_account_id_here
CLOUDFLARE_ZONE_ID=your_production_zone_id_here
CLOUDFLARE_ZONE_ID_STAGING=your_staging_zone_id_here
```

### 2. Build and Deploy

```bash
# Install dependencies (none required!)
bun install

# Build the worker
bun run build

# Deploy to staging
bun run deploy:staging

# Deploy to production
bun run deploy:production
```

### 3. Test Deployment

```bash
# Run health checks
bun run test-deploy --env=staging

# Test WebSocket connection
curl -H "Upgrade: websocket" https://bridge-staging.bitchat.app/bridge/global
```

## API Endpoints

### HTTP Endpoints

#### `GET /health`
Health check endpoint.

**Response:**
```
OK
```

#### `GET /bridges`
List available bridge endpoints.

**Response:**
```json
{
  "endpoints": [
    {
      "id": "global",
      "region": "auto",
      "status": "healthy"
    },
    {
      "id": "us-east",
      "region": "us-east-1", 
      "status": "healthy"
    }
  ]
}
```

#### `GET /bridge/{bridgeId}/stats`
Get bridge statistics (connections, messages, uptime).

**Response:**
```json
{
  "totalMessages": 1234,
  "activeConnections": 5,
  "uptime": 3600000,
  "bufferedMessages": 12
}
```

### WebSocket Endpoints

#### `WS /bridge/{bridgeId}`
Main WebSocket relay endpoint.

**Connection Flow:**
1. Client connects to WebSocket
2. Server sends welcome message with session ID
3. Client can send/receive encrypted messages
4. Server relays messages to all other connected clients

**Message Types:**

##### Welcome Message (Server → Client)
```json
{
  "type": "welcome",
  "sessionId": "uuid-here",
  "timestamp": 1640995200000
}
```

##### Data Message (Client ↔ Server)
```json
{
  "type": "data",
  "payload": {
    "encryptedData": [1, 2, 3, ...],
    "signature": [4, 5, 6, ...],
    "ttl": 5,
    "timestamp": 1640995200000
  }
}
```

##### Heartbeat (Client → Server)
```json
{
  "type": "heartbeat",
  "timestamp": 1640995200000
}
```

##### Heartbeat ACK (Server → Client)
```json
{
  "type": "heartbeat_ack",
  "timestamp": 1640995200000
}
```

## Security Model

### Privacy Guarantees

1. **Zero-Knowledge**: Server cannot decrypt message content
2. **No User Tracking**: No persistent user identifiers
3. **Ephemeral Sessions**: Session IDs are temporary and random
4. **No Message Storage**: Messages only buffered briefly for offline clients
5. **No Metadata Logging**: No IP addresses or user data logged

### Message Security

- **End-to-End Encryption**: Messages encrypted with Curve25519 + AES-256-GCM
- **Digital Signatures**: Ed25519 signatures prevent message tampering
- **TTL Protection**: Time-to-live prevents infinite message loops
- **Replay Protection**: Timestamp validation prevents replay attacks

### Infrastructure Security

- **TLS 1.3**: All connections encrypted in transit
- **Cloudflare Security**: DDoS protection and edge security
- **Rate Limiting**: Prevents abuse and resource exhaustion
- **Geographic Distribution**: Multiple regions for redundancy

## Deployment

### Environments

#### Staging
- **URL**: `https://bridge-staging.bitchat.app`
- **Purpose**: Testing and development
- **Auto-deploy**: On push to staging branch

#### Production  
- **URL**: `https://bridge.bitchat.app`
- **Purpose**: Live user traffic
- **Manual deploy**: Requires explicit deployment

### Deployment Commands

```bash
# Build only
bun run build

# Deploy to staging
bun run deploy:staging

# Deploy to production (requires confirmation)
bun run deploy:production

# Dry run (preview changes)
bun run deploy:staging --dry-run

# Verbose output
bun run deploy:staging --verbose

# Test deployment
bun run test-deploy --env=staging

# Cleanup deployment
bun run deploy:staging --cleanup
```

### Deployment Process

1. **Credential Validation**: Verify Cloudflare API access
2. **Build Worker**: Compile TypeScript to optimized JavaScript
3. **Upload Script**: Deploy worker code to Cloudflare
4. **Configure Durable Objects**: Set up persistent WebSocket handlers
5. **Route Configuration**: Map custom domains to worker
6. **Health Checks**: Verify deployment is working

### Monitoring

#### Built-in Metrics
- Active WebSocket connections
- Message throughput (messages/second)
- Error rates and types
- Response times
- Geographic distribution

#### Cloudflare Analytics
- Request volume and patterns
- Error rates by region
- Performance metrics
- Security events

#### Custom Monitoring
```bash
# Get bridge statistics
curl https://bridge.bitchat.app/bridge/global/stats

# Check health
curl https://bridge.bitchat.app/health
```

## Development

### Local Development

```bash
# Watch mode for development
bun run dev

# Build with source maps
bun run build --sourcemap

# Run tests
bun test

# Lint code
bun run lint
```

### Testing

#### Unit Tests
```bash
# Run all tests
bun test

# Run specific test file
bun test src/bridge-relay.test.ts

# Watch mode
bun test --watch
```

#### Integration Tests
```bash
# Test deployment
bun run test-deploy

# Test WebSocket connection
bun run test-websocket

# Load testing
bun run test-load
```

### Code Structure

#### Core Components

**`src/index.ts`** - Main worker entry point
- Routes HTTP requests
- Handles CORS preflight
- Manages Durable Object instances

**`src/bridge-relay.ts`** - WebSocket relay logic
- Manages client connections
- Relays encrypted messages
- Handles session lifecycle

**`src/types.ts`** - TypeScript definitions
- Message format types
- API response types
- Configuration interfaces

#### Deployment Infrastructure

**`deploy/deploy.ts`** - Main deployment orchestrator
- Builds and uploads worker
- Configures Durable Objects
- Sets up routing

**`deploy/cloudflare-api.ts`** - Native API client
- Zero-dependency Cloudflare API
- Full TypeScript support
- Comprehensive error handling

**`deploy/utils.ts`** - Deployment utilities
- Logging and progress indicators
- Retry logic and error handling
- Environment validation

## Configuration

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with Workers permissions | Yes |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID | Yes |
| `CLOUDFLARE_ZONE_ID` | Zone ID for production domain | Yes |
| `CLOUDFLARE_ZONE_ID_STAGING` | Zone ID for staging domain | Yes |

### Deployment Configuration

Edit `deploy/config.ts` to customize:

```typescript
export const deploymentConfigs = {
  staging: {
    scriptName: "bitchat-bridge-staging",
    routes: [
      {
        pattern: "bridge-staging.bitchat.app/*",
        zone: process.env.CLOUDFLARE_ZONE_ID_STAGING!
      }
    ]
  },
  production: {
    scriptName: "bitchat-bridge",
    routes: [
      {
        pattern: "bridge.bitchat.app/*", 
        zone: process.env.CLOUDFLARE_ZONE_ID!
      }
    ]
  }
};
```

## Performance

### Scalability

- **Global Edge**: Deployed to 200+ Cloudflare locations
- **Auto-scaling**: Handles traffic spikes automatically
- **Low Latency**: Sub-100ms response times globally
- **High Availability**: 99.9%+ uptime SLA

### Resource Usage

- **Memory**: ~10MB per Durable Object instance
- **CPU**: Minimal - mostly I/O bound WebSocket relay
- **Storage**: Ephemeral only - no persistent data
- **Bandwidth**: ~1KB per message relayed

### Cost Optimization

- **Durable Objects**: $0.50 per million requests
- **Workers**: $0.15 per million requests  
- **Bandwidth**: $0.045 per GB
- **Estimated**: ~$100/month for 1000 active users

## Troubleshooting

### Common Issues

#### Deployment Failures

**Invalid API Token**
```bash
# Verify token has correct permissions
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify
```

**Zone ID Issues**
```bash
# List available zones
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/zones
```

**Durable Object Limits**
- Maximum 1000 Durable Objects per account
- Contact Cloudflare support for limit increases

#### Runtime Issues

**WebSocket Connection Failures**
- Check CORS headers
- Verify TLS certificate
- Test with WebSocket client tools

**Message Relay Problems**
- Check TTL values (should be > 0)
- Verify message format matches schema
- Monitor error logs in Cloudflare dashboard

#### Performance Issues

**High Latency**
- Check client geographic location
- Consider additional bridge regions
- Monitor Cloudflare analytics

**Connection Drops**
- Implement client-side reconnection
- Check heartbeat intervals
- Monitor network stability

### Debugging

#### Enable Verbose Logging
```bash
# Deploy with debug mode
bun run deploy:staging --verbose

# Check worker logs
wrangler tail bitchat-bridge-staging
```

#### Test WebSocket Manually
```javascript
// Browser console test
const ws = new WebSocket('wss://bridge-staging.bitchat.app/bridge/global');
ws.onopen = () => console.log('Connected');
ws.onmessage = (e) => console.log('Message:', e.data);
ws.send(JSON.stringify({type: 'heartbeat', timestamp: Date.now()}));
```

#### Health Check Script
```bash
#!/bin/bash
# health-check.sh
curl -f https://bridge.bitchat.app/health || exit 1
curl -f https://bridge.bitchat.app/bridges || exit 1
echo "Bridge server healthy"
```

## Contributing

### Development Workflow

1. **Fork Repository**: Create your own fork
2. **Create Branch**: `git checkout -b feature/bridge-improvement`
3. **Make Changes**: Implement your feature
4. **Test Locally**: `bun test && bun run build`
5. **Deploy Staging**: `bun run deploy:staging`
6. **Test Integration**: Verify with bitchat app
7. **Submit PR**: Create pull request with description

### Code Standards

- **TypeScript**: Strict mode enabled
- **Formatting**: Use Prettier defaults
- **Linting**: ESLint with recommended rules
- **Testing**: Unit tests for all new features
- **Documentation**: Update README for API changes

### Security Guidelines

- **No Logging**: Never log message content or user data
- **Minimal State**: Keep server state ephemeral
- **Input Validation**: Validate all client inputs
- **Rate Limiting**: Implement abuse prevention
- **Audit Trail**: Document security-relevant changes

## License

This project is released into the public domain under the [Unlicense](https://unlicense.org).

## Support

- **Issues**: [GitHub Issues](https://github.com/bitchat/bitchat/issues)
- **Documentation**: [bitchat.app/docs](https://bitchat.app/docs)
- **Community**: [Discord Server](https://discord.gg/bitchat)

---

**Built with ❤️ for privacy and decentralization**