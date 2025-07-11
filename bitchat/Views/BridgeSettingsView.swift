import SwiftUI

struct BridgeSettingsView: View {
    @ObservedObject var bridgeManager: BridgeManager
    @State private var showingAddBridge = false
    @State private var newBridgeURL = ""
    @State private var newBridgeName = ""
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Bridge Status")) {
                    Toggle("Enable Bridge Connections", isOn: Binding(
                        get: { bridgeManager.isEnabled },
                        set: { enabled in
                            if enabled {
                                bridgeManager.enableBridges()
                            } else {
                                bridgeManager.disableBridges()
                            }
                        }
                    ))
                    
                    if bridgeManager.isEnabled {
                        Text("Bridge connections allow your local mesh to connect with remote networks via internet infrastructure.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Active Bridges")) {
                    if bridgeManager.activeBridges.isEmpty {
                        Text("No bridges configured")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(bridgeManager.activeBridges) { bridge in
                            BridgeConnectionRow(bridge: bridge)
                        }
                        .onDelete(perform: deleteBridge)
                    }
                }
                
                Section(header: Text("Commands")) {
                    VStack(alignment: .leading, spacing: 8) {
                        CommandHelpRow(command: "/bridge-connect <url> [name]", description: "Connect to a bridge")
                        CommandHelpRow(command: "/bridge-disconnect <url>", description: "Disconnect from a bridge")
                        CommandHelpRow(command: "/bridge-list", description: "List all bridges")
                        CommandHelpRow(command: "/bridge-enable", description: "Enable bridge connections")
                        CommandHelpRow(command: "/bridge-disable", description: "Disable bridge connections")
                        CommandHelpRow(command: "/bridge-status", description: "Show bridge status")
                    }
                    .font(.caption)
                }
                
                Section(header: Text("Privacy & Security")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Bridge connections are opt-in only")
                        Text("• All messages remain end-to-end encrypted")
                        Text("• Bridge uses separate authentication")
                        Text("• You control which bridges to connect to")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Bridge Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add Bridge") {
                        showingAddBridge = true
                    }
                }
            }
            .sheet(isPresented: $showingAddBridge) {
                AddBridgeView(
                    bridgeManager: bridgeManager,
                    isPresented: $showingAddBridge
                )
            }
        }
    }
    
    private func deleteBridge(at offsets: IndexSet) {
        for index in offsets {
            let bridge = bridgeManager.activeBridges[index]
            bridgeManager.removeBridge(id: bridge.id)
        }
    }
}

struct BridgeConnectionRow: View {
    let bridge: BridgeManager.BridgeConnection
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bridge.name)
                    .font(.headline)
                Spacer()
                Image(systemName: bridge.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(bridge.isConnected ? .green : .red)
            }
            
            Text(bridge.url.absoluteString)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let lastConnected = bridge.lastConnected {
                Text("Last connected: \(lastConnected.formatted())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CommandHelpRow: View {
    let command: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
            Text(description)
                .foregroundColor(.secondary)
        }
    }
}

struct AddBridgeView: View {
    let bridgeManager: BridgeManager
    @Binding var isPresented: Bool
    
    @State private var url = ""
    @State private var name = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Bridge Details")) {
                    TextField("Bridge URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    
                    TextField("Bridge Name (optional)", text: $name)
                }
                
                Section(header: Text("Examples")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("wss://bridge.example.com/bridge/connect")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("ws://localhost:8787/bridge/connect")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(footer: Text("Enter the WebSocket URL of the bridge service. Use wss:// for secure connections or ws:// for local testing.")) {
                    EmptyView()
                }
            }
            .navigationTitle("Add Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        addBridge()
                    }
                    .disabled(url.isEmpty)
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func addBridge() {
        guard let bridgeURL = URL(string: url) else {
            errorMessage = "Invalid URL format"
            showingError = true
            return
        }
        
        // Validate WebSocket protocol
        guard bridgeURL.scheme == "ws" || bridgeURL.scheme == "wss" else {
            errorMessage = "Bridge URL must use ws:// or wss:// protocol"
            showingError = true
            return
        }
        
        let bridgeName = name.isEmpty ? (bridgeURL.host ?? "Unknown Bridge") : name
        
        bridgeManager.addBridge(url: bridgeURL, name: bridgeName)
        isPresented = false
    }
}

#Preview {
    let encryptionService = EncryptionService()
    let bridgeManager = BridgeManager(encryptionService: encryptionService)
    
    return BridgeSettingsView(bridgeManager: bridgeManager)
}