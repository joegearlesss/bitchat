import Foundation

extension ChatViewModel {
    func handleBridgeCommand(_ command: String, arguments: [String]) {
        switch command {
        case "bridge-connect":
            handleBridgeConnect(arguments)
        case "bridge-disconnect":
            handleBridgeDisconnect(arguments)
        case "bridge-list":
            handleBridgeList()
        case "bridge-enable":
            handleBridgeEnable()
        case "bridge-disable":
            handleBridgeDisable()
        case "bridge-status":
            handleBridgeStatus()
        default:
            addSystemMessage("unknown bridge command: /\(command)")
        }
    }
    
    private func handleBridgeConnect(_ arguments: [String]) {
        guard arguments.count >= 1 else {
            addSystemMessage("usage: /bridge-connect <url> [name]")
            return
        }
        
        guard let url = URL(string: arguments[0]) else {
            addSystemMessage("invalid URL: \(arguments[0])")
            return
        }
        
        // Validate that it's a WebSocket URL
        guard url.scheme == "ws" || url.scheme == "wss" else {
            addSystemMessage("bridge URL must use ws:// or wss:// protocol")
            return
        }
        
        let name = arguments.count > 1 ? arguments[1] : url.host ?? "unknown bridge"
        
        bridgeManager?.addBridge(url: url, name: name)
        addSystemMessage("added bridge: \(name) (\(url.absoluteString))")
    }
    
    private func handleBridgeDisconnect(_ arguments: [String]) {
        guard arguments.count >= 1 else {
            addSystemMessage("usage: /bridge-disconnect <url>")
            return
        }
        
        guard let url = URL(string: arguments[0]) else {
            addSystemMessage("invalid URL: \(arguments[0])")
            return
        }
        
        if let connection = bridgeManager?.activeBridges.first(where: { $0.url == url }) {
            bridgeManager?.removeBridge(id: connection.id)
            addSystemMessage("disconnected from bridge: \(connection.name)")
        } else {
            addSystemMessage("bridge not found: \(url.absoluteString)")
        }
    }
    
    private func handleBridgeList() {
        guard let bridgeManager = bridgeManager else {
            addSystemMessage("bridge manager not available")
            return
        }
        
        if bridgeManager.activeBridges.isEmpty {
            addSystemMessage("no bridges configured")
            return
        }
        
        addSystemMessage("active bridges:")
        for bridge in bridgeManager.activeBridges {
            let status = bridge.isConnected ? "✅ connected" : "❌ disconnected"
            let lastSeen = bridge.lastConnected?.formatted() ?? "never"
            addSystemMessage("  • \(bridge.name): \(status) (last: \(lastSeen))")
        }
        
        let connectedCount = bridgeManager.activeBridges.filter(\.isConnected).count
        let totalCount = bridgeManager.activeBridges.count
        addSystemMessage("total: \(connectedCount)/\(totalCount) connected")
    }
    
    private func handleBridgeEnable() {
        guard let bridgeManager = bridgeManager else {
            addSystemMessage("bridge manager not available")
            return
        }
        
        bridgeManager.enableBridges()
        addSystemMessage("bridge connections enabled")
        
        if bridgeManager.activeBridges.isEmpty {
            addSystemMessage("no bridges configured. use /bridge-connect to add bridges.")
        }
    }
    
    private func handleBridgeDisable() {
        guard let bridgeManager = bridgeManager else {
            addSystemMessage("bridge manager not available")
            return
        }
        
        bridgeManager.disableBridges()
        addSystemMessage("bridge connections disabled")
    }
    
    private func handleBridgeStatus() {
        guard let bridgeManager = bridgeManager else {
            addSystemMessage("bridge manager not available")
            return
        }
        
        let status = bridgeManager.isEnabled ? "enabled" : "disabled"
        let connectedCount = bridgeManager.activeBridges.filter(\.isConnected).count
        let totalCount = bridgeManager.activeBridges.count
        
        addSystemMessage("bridge status: \(status)")
        addSystemMessage("bridges: \(connectedCount)/\(totalCount) connected")
        
        if bridgeManager.isEnabled && totalCount == 0 {
            addSystemMessage("no bridges configured. use /bridge-connect to add bridges.")
        }
    }
    
    private func addSystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        
        // Add to appropriate message array based on current context
        if let channel = currentChannel {
            if channelMessages[channel] == nil {
                channelMessages[channel] = []
            }
            channelMessages[channel]?.append(systemMessage)
        } else if selectedPrivateChatPeer != nil {
            // Don't add bridge commands to private chats
            messages.append(systemMessage)
        } else {
            messages.append(systemMessage)
        }
    }
}