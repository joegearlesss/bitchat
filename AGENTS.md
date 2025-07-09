# Project Summary: bitchat

## Overview
bitchat is a decentralized, offline-first secure messaging application that uses Bluetooth Low Energy (BLE) mesh networking for communication without requiring internet connectivity. The app is built using SwiftUI and targets iOS, iPadOS, and macOS platforms.

## Key Features

### Core Functionality
- **Offline Mesh Networking**: Uses BLE to create a mesh network for message relay and extended range (300m+)
- **End-to-End Encryption**: All messages encrypted with Curve25519 + AES-256-GCM
- **Real-time Chat**: Support for public chat, private messages, and channels
- **Store-and-Forward**: Messages cached for offline users, with persistent storage for favorites
- **Universal App**: Single codebase supporting iPhone, iPad, and Mac

### Privacy & Security
- **No Servers**: Completely peer-to-peer with no centralized infrastructure
- **Ephemeral Identity**: New peer ID generated each session to prevent tracking
- **Panic Mode**: Triple-tap to instantly clear all data for activist safety
- **Keychain Integration**: Secure storage of channel passwords
- **Cover Traffic**: Dummy messages for traffic analysis resistance

### Advanced Features
- **@Mentions**: Notification system for targeted messages
- **#Channels**: Topic-based group conversations with optional password protection
- **Favorites System**: Star users to cache messages indefinitely when they're offline
- **Message Retention**: Optional persistent storage for channel messages
- **Delivery/Read Receipts**: Track message delivery status
- **Share Extension**: Share URLs and text from other apps
- **Haptic Feedback**: Context-aware vibrations (iOS)
- **WiFi Bridge**: Internet relay servers for global mesh connectivity
- **Hybrid Transport**: Intelligent switching between BLE and WiFi bridges
- **Bridge Discovery**: Automatic selection of optimal relay servers

## Technical Architecture

### Core Components

#### 1. BluetoothMeshService
- **Purpose**: Manages BLE mesh networking, encryption, and message routing
- **Key Features**:
  - Probabilistic flooding for message relay
  - Battery-aware scanning with duty cycling
  - Store-and-forward message caching
  - Fragment handling for large messages
  - Connection pooling with exponential backoff

#### 2. ChatViewModel
- **Purpose**: Main app state management and business logic
- **Key Features**:
  - Message handling for public/private/channel contexts
  - Channel management with password protection
  - Autocomplete for @mentions
  - Command processing (/join, /msg, etc.)
  - Favorites and blocking functionality

#### 3. EncryptionService
- **Purpose**: Handles all cryptographic operations
- **Features**:
  - Curve25519 key exchange
  - AES-256-GCM message encryption
  - Digital signatures for message integrity
  - Identity key management

#### 4. Supporting Services
- **MessageRetentionService**: Encrypted local storage for channel messages
- **MessageRetryService**: Automatic retry for failed message sends
- **NotificationService**: Local notifications for mentions and private messages
- **KeychainManager**: Secure storage for channel passwords
- **BatteryOptimizer**: Adaptive performance based on battery level

### User Interface
- **ContentView**: Main chat interface with sidebar navigation
- **AppInfoView**: Feature documentation and help
- **Share Extension**: iOS share sheet integration
- **Responsive Design**: Optimized for iPhone, iPad, and Mac screen sizes

## Technical Specifications

### Networking
- **Protocol**: Custom binary protocol over BLE
- **Range**: ~100m direct, 300m+ with mesh relay
- **Message Size**: Up to 512 bytes with fragmentation support
- **TTL**: Adaptive hop count (3-6) based on network size

### Security
- **Key Exchange**: Curve25519 elliptic curve cryptography
- **Message Encryption**: AES-256-GCM authenticated encryption
- **Signatures**: Ed25519 digital signatures
- **Channel Encryption**: Password-derived keys with PBKDF2
- **Identity**: Ephemeral peer IDs (8 hex characters per session)

### Storage
- **Messages**: Ephemeral by default, optional encrypted retention
- **Passwords**: Stored in device Keychain
- **Settings**: UserDefaults for non-sensitive data
- **Favorites**: Persistent based on public key fingerprints

### Performance
- **Battery Optimization**: Adaptive scanning based on battery level and app state
- **Memory Management**: Bloom filters for efficient duplicate detection
- **Network Scaling**: Probabilistic relay reduces congestion
- **Message Ordering**: Timestamp-based with retry mechanisms

## Commands & Usage

### Basic Commands
- `/j #channel` - Join or create a channel
- `/m @nickname` - Send private message
- `/w` - Show who's online
- `/channels` - List all discovered channels
- `/clear` - Clear current chat messages

### Moderation Commands
- `/block @nickname` - Block a user
- `/unblock @nickname` - Unblock a user
- `/block` - List blocked users

### Fun Commands
- `/hug @nickname` - Send a virtual hug
- `/slap @nickname` - Slap with a trout (IRC-style)

### Channel Owner Commands
- `/pass <password>` - Set/change channel password
- `/save` - Toggle message retention for channel
- `/transfer @nickname` - Transfer channel ownership

## File Structure

### Main Application
- `BitchatApp.swift` - App entry point and URL handling
- `ContentView.swift` - Main UI with chat interface and sidebar
- `ChatViewModel.swift` - Core business logic and state management
- `AppInfoView.swift` - Help and feature documentation

### Networking & Security
- `BluetoothMeshService.swift` - BLE mesh networking implementation
- `EncryptionService.swift` - Cryptographic operations
- `MessageRetryService.swift` - Automatic message retry logic
- `WiFiBridgeService.swift` - Internet bridge connectivity
- `BridgeDiscoveryService.swift` - Bridge endpoint discovery
- `HybridTransportManager.swift` - Multi-transport coordination

### Storage & Utilities
- `MessageRetentionService.swift` - Encrypted local message storage
- `KeychainManager.swift` - Secure password storage
- `NotificationService.swift` - Local notification management

### Extensions
- `ShareViewController.swift` - iOS share extension for URL/text sharing

### Bridge Infrastructure
- `bridge-server/` - Cloudflare Durable Object bridge server
- `bridge-server/src/index.ts` - Main worker entry point
- `bridge-server/src/bridge-relay.ts` - WebSocket relay implementation
- `bridge-server/deploy/` - Zero-dependency deployment scripts
- `bridge-server/scripts/` - Build and testing utilities

## Development Status

### Completed Features
✅ Core mesh networking with BLE
✅ End-to-end encryption
✅ Public/private/channel messaging
✅ Password-protected channels
✅ Favorites and blocking system
✅ Message retention and store-and-forward
✅ Share extension
✅ Universal app (iOS/iPadOS/macOS)
✅ Panic mode for data clearing
✅ Battery optimization
✅ Haptic feedback
✅ **WiFi Bridge Support** - Internet relay for extended range
✅ **Hybrid Transport** - Seamless BLE + WiFi coordination
✅ **Bridge Discovery** - Automatic optimal bridge selection
✅ **Zero-Knowledge Bridges** - Privacy-preserving relay servers

### Architecture Strengths
- **Modular Design**: Clear separation of concerns
- **Security-First**: Comprehensive encryption and privacy features
- **Performance Optimized**: Battery-aware with scaling algorithms
- **User-Friendly**: Intuitive interface with powerful features
- **Cross-Platform**: Single codebase for all Apple platforms

### Use Cases
- **Activist Communications**: Secure, untraceable messaging
- **Emergency Situations**: Communication when internet is down
- **Events & Gatherings**: Local group communication
- **Privacy-Conscious Users**: No-server messaging
- **Remote Areas**: Communication without cellular coverage

## Build Requirements
- Xcode 15.0+
- iOS 17.0+ / macOS 14.0+
- Swift 5.9+
- Core Bluetooth framework
- CryptoKit framework

## Development Guidelines

### ⚠️ IMPORTANT: Project File Modifications
**STRICTLY PROHIBITED**: Adding, modifying, or removing files in the `bitchat.xcodeproj` folder without explicit user approval. This includes:
- Adding new source files to the project
- Modifying project settings or configurations
- Creating new targets or schemes
- Adding dependencies or frameworks
- Changing build settings or Info.plist entries

**Required Process**: Before making any changes to the Xcode project structure:
1. Request explicit permission from the user
2. Clearly explain what files will be added/modified
3. Wait for user confirmation before proceeding
4. Only make changes after receiving explicit approval

This ensures project integrity and prevents unintended modifications to the build system.

## License
This project is released into the public domain under the Unlicense.