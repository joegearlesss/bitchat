![ChatGPT Image Jul 5, 2025 at 06_07_31 PM](https://github.com/user-attachments/assets/2660f828-49c7-444d-beca-d8b01854667a)
# bitchat

> [!WARNING]
> This software has not received external security review and may contain vulnerabilities and may not necessarily meet its stated security goals. Do not use it for sensitive use cases, and do not rely on its security until it has been reviewed. Work in progress.

A secure, decentralized, peer-to-peer messaging app that works over Bluetooth mesh networks with optional WiFi bridge support. Connect locally via Bluetooth or globally via internet relay servers - all with end-to-end encryption and no accounts required.

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.

## Features

- **Hybrid Transport**: Bluetooth LE mesh + optional WiFi bridge for global connectivity
- **Zero-Knowledge Relay**: Internet bridges cannot decrypt messages - privacy preserved
- **End-to-End Encryption**: X25519 key exchange + AES-256-GCM for private messages
- **Channel-Based Chats**: Topic-based group messaging with optional password protection
- **Store & Forward**: Messages cached for offline peers and delivered when they reconnect
- **Privacy First**: No accounts, no phone numbers, no persistent identifiers
- **IRC-Style Commands**: Familiar `/join`, `/msg`, `/who` style interface
- **Message Retention**: Optional channel-wide message saving controlled by channel owners
- **Universal App**: Native support for iOS and macOS
- **Cover Traffic**: Timing obfuscation and dummy messages for enhanced privacy
- **Emergency Wipe**: Triple-tap to instantly clear all data
- **Performance Optimizations**: LZ4 message compression, adaptive battery modes, and optimized networking

## Setup

### Option 1: Using XcodeGen (Recommended)

1. Install XcodeGen if you haven't already:
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   cd bitchat
   xcodegen generate
   ```

3. Open the generated project:
   ```bash
   open bitchat.xcodeproj
   ```

### Option 2: Using Swift Package Manager

1. Open the project in Xcode:
   ```bash
   cd bitchat
   open Package.swift
   ```

2. Select your target device and run

### Option 3: Manual Xcode Project

1. Open Xcode and create a new iOS/macOS App
2. Copy all Swift files from the `bitchat` directory into your project
3. Update Info.plist with Bluetooth permissions
4. Set deployment target to iOS 16.0 / macOS 13.0

## Usage

### Basic Commands

- `/j #channel` - Join or create a channel
- `/m @name message` - Send a private message
- `/w` - List online users
- `/channels` - Show all discovered channels
- `/block @name` - Block a peer from messaging you
- `/block` - List all blocked peers
- `/unblock @name` - Unblock a peer
- `/clear` - Clear chat messages
- `/pass [password]` - Set/change channel password (owner only)
- `/transfer @name` - Transfer channel ownership
- `/save` - Toggle message retention for channel (owner only)
- `/bridge <on|off|status>` - Control WiFi bridge connectivity

### Getting Started

1. Launch bitchat on your device
2. Set your nickname (or use the auto-generated one)
3. You'll automatically connect to nearby peers via Bluetooth
4. Optionally enable WiFi bridge with `/bridge on` for global connectivity
5. Join a channel with `/j #general` or start chatting in public
6. Messages relay through the mesh network and bridge servers to reach distant peers

### Channel Features

- **Password Protection**: Channel owners can set passwords with `/pass`
- **Message Retention**: Owners can enable mandatory message saving with `/save`
- **@ Mentions**: Use `@nickname` to mention users (with autocomplete)
- **Ownership Transfer**: Pass control to trusted users with `/transfer`

### WiFi Bridge Features

- **Global Connectivity**: Connect mesh islands across the internet
- **Zero-Knowledge Relay**: Bridge servers cannot decrypt your messages
- **Automatic Failover**: Seamlessly switches between Bluetooth and WiFi
- **Bridge Commands**:
  - `/bridge on` - Enable WiFi bridge connectivity
  - `/bridge off` - Disable bridge (Bluetooth-only mode)
  - `/bridge status` - Show connection status and transport info
- **Smart Transport Selection**: Automatically uses the best available connection
- **Privacy Preserved**: End-to-end encryption maintained through bridge servers

## Security & Privacy

### Encryption
- **Private Messages**: X25519 key exchange + AES-256-GCM encryption
- **Channel Messages**: Argon2id password derivation + AES-256-GCM
- **Digital Signatures**: Ed25519 for message authenticity
- **Forward Secrecy**: New key pairs generated each session

### Privacy Features
- **No Registration**: No accounts, emails, or phone numbers required
- **Ephemeral by Default**: Messages exist only in device memory
- **Cover Traffic**: Random delays and dummy messages prevent traffic analysis
- **Emergency Wipe**: Triple-tap logo to instantly clear all data
- **Local-First**: Works completely offline, optional bridge servers for global reach

## Performance & Efficiency

### Message Compression
- **LZ4 Compression**: Automatic compression for messages >100 bytes
- **30-70% bandwidth savings** on typical text messages
- **Smart compression**: Skips already-compressed data

### Battery Optimization
- **Adaptive Power Modes**: Automatically adjusts based on battery level
  - Performance mode: Full features when charging or >60% battery
  - Balanced mode: Default operation (30-60% battery)
  - Power saver: Reduced scanning when <30% battery
  - Ultra-low power: Emergency mode when <10% battery
- **Background efficiency**: Automatic power saving when app backgrounded
- **Configurable scanning**: Duty cycle adapts to battery state

### Network Efficiency
- **Optimized Bloom filters**: Faster duplicate detection with less memory
- **Message aggregation**: Batches small messages to reduce transmissions
- **Adaptive connection limits**: Adjusts peer connections based on power mode

## Technical Architecture

### Binary Protocol
bitchat uses an efficient binary protocol optimized for Bluetooth LE:
- Compact packet format with 1-byte type field
- TTL-based message routing (max 7 hops)
- Automatic fragmentation for large messages
- Message deduplication via unique IDs

### Hybrid Transport System
- **Bluetooth LE Mesh**: Local peer-to-peer networking (100m range, extendable via relay)
- **WiFi Bridge**: Optional internet relay servers for global connectivity
- **Intelligent Switching**: Automatically selects optimal transport based on conditions
- **Zero-Knowledge Relay**: Bridge servers cannot decrypt messages - end-to-end encryption maintained

### Mesh Networking
- Each device acts as both client and peripheral
- Automatic peer discovery and connection management
- Store-and-forward for offline message delivery
- Adaptive duty cycling for battery optimization

### WiFi Bridge Infrastructure
- **Cloudflare Workers**: Serverless WebSocket relay infrastructure
- **Global Edge Network**: Low-latency connections worldwide
- **Auto-Discovery**: Automatic selection of optimal bridge endpoints
- **Privacy-Preserving**: Bridges relay encrypted packets without access to content

For detailed protocol documentation, see the [Technical Whitepaper](WHITEPAPER.md).

## Building for Production

### iOS/macOS App
1. Set your development team in project settings
2. Configure code signing
3. Archive and distribute through App Store or TestFlight

### Bridge Server (Optional)
If you want to run your own bridge infrastructure:

1. Install dependencies:
   ```bash
   cd bridge-server
   bun install
   ```

2. Configure environment:
   ```bash
   cp .env.example .env
   # Add your Cloudflare API credentials
   ```

3. Deploy to Cloudflare Workers:
   ```bash
   bun run deploy:staging
   # or for production:
   bun run deploy:production
   ```

4. Update iOS app endpoints in `WiFiBridgeService.swift` with your bridge URLs

## Android Compatibility

The protocol is designed to be platform-agnostic. An Android client can be built using:
- **Bluetooth LE APIs**: For local mesh networking
- **WebSocket APIs**: For WiFi bridge connectivity
- **Same packet structure and encryption**: Full protocol compatibility
- **Compatible service/characteristic UUIDs**: Seamless interoperability

Android devices can connect to the same bridge servers and communicate with iOS/macOS clients seamlessly.
