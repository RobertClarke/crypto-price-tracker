import Cocoa
import Foundation

struct CryptoCurrency {
    let symbol: String      // Trading pair (e.g., "BTC-USD")
    let baseCurrency: String // Base currency (e.g., "BTC")
    let name: String
    let emoji: String
    var price: Double
    var open24h: Double
    var changePercent24h: Double
    var volume24h: Double
    var lastUpdate: Date
    
    init(symbol: String, baseCurrency: String, name: String, emoji: String = "💰") {
        self.symbol = symbol
        self.baseCurrency = baseCurrency
        self.name = name
        self.emoji = emoji
        self.price = 0.0
        self.open24h = 0.0
        self.changePercent24h = 0.0
        self.volume24h = 0.0
        self.lastUpdate = Date()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, URLSessionWebSocketDelegate {
    
    var statusItem: NSStatusItem?
    var webSocketTask: URLSessionWebSocketTask?
    var urlSession: URLSession?
    var cryptocurrencies: [String: CryptoCurrency] = [:]
    var selectedCryptos: [String] = ["BTC-USD"]
    var selectedCrypto: String { selectedCryptos.first ?? "BTC-USD" }
    var reconnectTimer: Timer?
    var healthCheckTimer: Timer?
    var lastMessageTime: Date = Date()
    var isConnected: Bool = false
    
    // Health check interval (seconds) - check every 30s
    private let healthCheckInterval: TimeInterval = 30
    // Consider connection stale if no message for this long (seconds)
    private let staleConnectionThreshold: TimeInterval = 60
    
    // Known crypto names and emojis for popular coins
    private let knownCryptos: [String: (name: String, emoji: String)] = [
        "BTC": ("Bitcoin", "₿"),
        "ETH": ("Ethereum", "Ξ"),
        "SOL": ("Solana", "◎"),
        "ADA": ("Cardano", "🅰️"),
        "DOT": ("Polkadot", "🔴"),
        "LINK": ("Chainlink", "🔗"),
        "AVAX": ("Avalanche", "🔺"),
        "XRP": ("XRP", "💧"),
        "LTC": ("Litecoin", "🪙"),
        "MATIC": ("Polygon", "🔷"),
        "POL": ("Polygon", "🔷"),
        "ATOM": ("Cosmos", "⚛️"),
        "UNI": ("Uniswap", "🦄"),
        "XLM": ("Stellar", "⭐"),
        "FIL": ("Filecoin", "📁"),
        "ALGO": ("Algorand", "🔺"),
        "NEAR": ("NEAR Protocol", "🔮"),
        "APT": ("Aptos", "🚀"),
        "OP": ("Optimism", "🔴"),
        "ARB": ("Arbitrum", "🔵"),
        "SUI": ("Sui", "🌊"),
        "INJ": ("Injective", "💉"),
        "MANA": ("Decentraland", "🏗️"),
        "SAND": ("The Sandbox", "🏖️"),
        "AXS": ("Axie Infinity", "🎮"),
        "AAVE": ("Aave", "👻"),
        "COMP": ("Compound", "🏛️"),
        "MKR": ("Maker", "🎯"),
        "CRV": ("Curve", "〰️"),
        "SUSHI": ("SushiSwap", "🍣"),
        "LRC": ("Loopring", "🔄"),
        "DOGE": ("Dogecoin", "🐕"),
        "SHIB": ("Shiba Inu", "🐶"),
        "PEPE": ("Pepe", "🐸"),
        "WIF": ("dogwifhat", "🐕"),
        "BONK": ("Bonk", "🐕"),
        "RENDER": ("Render", "🎨"),
        "FET": ("Fetch.ai", "🤖"),
        "GRT": ("The Graph", "📊"),
        "IMX": ("Immutable", "🎮"),
        "SEI": ("Sei", "🌊"),
        "TIA": ("Celestia", "✨"),
        "JUP": ("Jupiter", "🪐"),
        "PYTH": ("Pyth Network", "🐍"),
        "WLD": ("Worldcoin", "🌍"),
        "STRK": ("Starknet", "⚡"),
        "ENA": ("Ethena", "🔷"),
        "W": ("Wormhole", "🕳️"),
        "ZRO": ("LayerZero", "0️⃣"),
        "EIGEN": ("EigenLayer", "🔷"),
        "XTZ": ("Tezos", "🔷"),
        "HBAR": ("Hedera", "🌀"),
        "VET": ("VeChain", "⚡"),
        "ICP": ("Internet Computer", "∞"),
        "TRUMP": ("Trump", "🇺🇸"),
    ]
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("🚀 App launched successfully!")
        setupStatusBar()
        print("📊 Status bar setup complete")
        
        // Register for system wake notifications
        registerForWakeNotifications()
        
        // Start health check timer
        startHealthCheckTimer()
        
        // Fetch available products from Coinbase, then connect
        fetchAvailableProducts()
    }
    
    // MARK: - Auto Reconnect Logic
    
    private func registerForWakeNotifications() {
        // Listen for system wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Listen for network changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        
        print("📡 Registered for system wake notifications")
    }
    
    @objc private func systemDidWake(_ notification: Notification) {
        print("💤 System woke from sleep - reconnecting...")
        
        // Small delay to allow network to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.forceReconnect()
        }
    }
    
    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.checkConnectionHealth()
        }
        print("🏥 Health check timer started (every \(Int(healthCheckInterval))s)")
    }
    
    private func checkConnectionHealth() {
        let timeSinceLastMessage = Date().timeIntervalSince(lastMessageTime)
        
        if !isConnected {
            print("🔴 Health check: Not connected - attempting reconnect")
            forceReconnect()
        } else if timeSinceLastMessage > staleConnectionThreshold {
            print("🟡 Health check: Connection stale (no message for \(Int(timeSinceLastMessage))s) - reconnecting")
            forceReconnect()
        } else {
            print("🟢 Health check: OK (last message \(Int(timeSinceLastMessage))s ago)")
        }
    }
    
    private func forceReconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        
        // Fetch fresh prices and reconnect
        fetchSelectedPrices()
        connectToWebSocket()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        reconnectTimer?.invalidate()
        healthCheckTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    private func setupStatusBar() {
        print("🔧 Setting up status bar...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.title = "₿ Loading..."
            button.target = self
            button.action = #selector(statusBarButtonClicked)
        }
        
        // Setup initial menu (will be rebuilt after products load)
        setupMenu()
        print("✅ Status bar setup completed")
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        
        let summaryTitle = selectedCryptos.isEmpty ? "Selected: None" : "Selected: \(selectedCryptos.joined(separator: ", "))"
        let currentPriceItem = NSMenuItem(title: summaryTitle, action: nil, keyEquivalent: "")
        currentPriceItem.tag = 100
        menu.addItem(currentPriceItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let allCryptosItem = NSMenuItem(title: "All Cryptocurrencies", action: nil, keyEquivalent: "")
        let allCryptosMenu = NSMenu()
        
        // Sort alphabetically by name A-Z
        let sortedCryptos = cryptocurrencies.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        
        for crypto in sortedCryptos {
            let isSelected = selectedCryptos.contains(crypto.symbol) ? " ✓" : ""
            let cryptoItem = NSMenuItem(title: "\(crypto.emoji) \(crypto.name) (\(crypto.baseCurrency))\(isSelected)", action: #selector(toggleCryptocurrency(_:)), keyEquivalent: "")
            cryptoItem.target = self
            cryptoItem.tag = crypto.symbol.hashValue
            cryptoItem.representedObject = crypto.symbol
            allCryptosMenu.addItem(cryptoItem)
        }
        
        allCryptosItem.submenu = allCryptosMenu
        menu.addItem(allCryptosItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let connectionItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectWebSocket), keyEquivalent: "r")
        connectionItem.target = self
        menu.addItem(connectionItem)
        
        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc func toggleCryptocurrency(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        if let idx = selectedCryptos.firstIndex(of: symbol) {
            selectedCryptos.remove(at: idx)
        } else {
            if selectedCryptos.count >= 3 {
                let alert = NSAlert()
                alert.messageText = "Selection limit reached"
                alert.informativeText = "You can select up to 3 currencies."
                alert.alertStyle = .warning
                alert.runModal()
            } else {
                selectedCryptos.append(symbol)
            }
        }
        
        // Fetch initial price for newly selected crypto
        for sym in selectedCryptos {
            if cryptocurrencies[sym]?.price == 0 {
                fetchTickerForSymbol(sym)
            }
        }
        
        updateStatusBarForSelectedCrypto()
        updateMenuPrices()
        
        // Reconnect WebSocket with new selection
        connectToWebSocket()
    }
    
    @objc func statusBarButtonClicked() {
        // Menu shows automatically
    }
    
    @objc func reconnectWebSocket() {
        print("Manual reconnect requested")
        fetchAvailableProducts()
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Crypto Price Monitor"
        alert.informativeText = "Real-time cryptocurrency prices in your status bar.\n\nDynamically loads all available trading pairs from Coinbase.\n\nCurrently tracking \(cryptocurrencies.count) cryptocurrencies.\n\nReal-time data from Coinbase WebSocket API"
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Fetch Available Products from Coinbase
    
    private func fetchAvailableProducts() {
        guard let url = URL(string: "https://api.exchange.coinbase.com/products") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else {
                print("Error fetching products: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            do {
                if let products = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    // Filter for online USD products
                    let usdProducts = products.filter { product in
                        let quoteCurrency = product["quote_currency"] as? String ?? ""
                        let status = product["status"] as? String ?? ""
                        return quoteCurrency == "USD" && status == "online"
                    }
                    
                    print("📊 Found \(usdProducts.count) USD trading pairs")
                    
                    // Create cryptocurrency entries
                    var newCryptos: [String: CryptoCurrency] = [:]
                    
                    for product in usdProducts {
                        guard let symbol = product["id"] as? String,
                              let baseCurrency = product["base_currency"] as? String else { continue }
                        
                        // Get name and emoji from known list, or use base currency
                        let info = self.knownCryptos[baseCurrency]
                        let name = info?.name ?? baseCurrency
                        let emoji = info?.emoji ?? "💰"
                        
                        newCryptos[symbol] = CryptoCurrency(
                            symbol: symbol,
                            baseCurrency: baseCurrency,
                            name: name,
                            emoji: emoji
                        )
                    }
                    
                    DispatchQueue.main.async {
                        self.cryptocurrencies = newCryptos
                        
                        // Make sure selected cryptos exist
                        self.selectedCryptos = self.selectedCryptos.filter { newCryptos[$0] != nil }
                        if self.selectedCryptos.isEmpty {
                            self.selectedCryptos = ["BTC-USD"]
                        }
                        
                        // Setup menu and fetch prices only for selected cryptos
                        self.setupMenu()
                        self.fetchSelectedPrices()
                        self.connectToWebSocket()
                    }
                }
            } catch {
                print("Error parsing products JSON: \(error)")
            }
        }
        task.resume()
    }
    
    // MARK: - Fetch Prices for Selected Cryptos Only
    
    private func fetchSelectedPrices() {
        for symbol in selectedCryptos {
            fetchTickerForSymbol(symbol)
        }
    }
    
    private func fetchTickerForSymbol(_ symbol: String) {
        guard let url = URL(string: "https://api.exchange.coinbase.com/products/\(symbol)/ticker") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else { return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let priceString = json["price"] as? String,
                       let price = Double(priceString) {
                        
                        // Also fetch 24h stats
                        self.fetch24hStatsForSymbol(symbol, currentPrice: price)
                    }
                }
            } catch {
                print("Error parsing ticker for \(symbol): \(error)")
            }
        }
        task.resume()
    }
    
    private func fetch24hStatsForSymbol(_ symbol: String, currentPrice: Double) {
        guard let url = URL(string: "https://api.exchange.coinbase.com/products/\(symbol)/stats") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else { return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let open = Double(json["open"] as? String ?? "0") ?? currentPrice
                    let changePercent = open > 0 ? ((currentPrice - open) / open) * 100 : 0
                    
                    DispatchQueue.main.async {
                        self.cryptocurrencies[symbol]?.price = currentPrice
                        self.cryptocurrencies[symbol]?.open24h = open
                        self.cryptocurrencies[symbol]?.changePercent24h = changePercent
                        self.updateUI()
                    }
                }
            } catch {}
        }
        task.resume()
    }
    
    // MARK: - Coinbase WebSocket
    
    private func connectToWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        
        guard let url = URL(string: "wss://ws-feed.exchange.coinbase.com") else {
            print("Invalid Coinbase WebSocket URL")
            return
        }
        
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        print("🔌 Connecting to Coinbase WebSocket...")
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ Coinbase WebSocket connected!")
        DispatchQueue.main.async {
            self.isConnected = true
            self.lastMessageTime = Date()
        }
        sendSubscription()
        receiveMessage()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("❌ WebSocket closed with code: \(closeCode)")
        DispatchQueue.main.async {
            self.isConnected = false
        }
        scheduleReconnect()
    }
    
    private func sendSubscription() {
        // Only subscribe to selected cryptos (max 3)
        let symbols = selectedCryptos
        
        guard !symbols.isEmpty else {
            print("No symbols to subscribe")
            return
        }
        
        let subscribeMessage: [String: Any] = [
            "type": "subscribe",
            "product_ids": symbols,
            "channels": ["ticker"]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: subscribeMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { error in
                    if let error = error {
                        print("Error sending subscription: \(error)")
                    } else {
                        print("📨 Subscribed to: \(symbols.joined(separator: ", "))")
                    }
                }
            }
        } catch {
            print("Error creating subscription JSON: \(error)")
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
                self?.scheduleReconnect()
                
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.processCoinbaseMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.processCoinbaseMessage(text)
                    }
                @unknown default:
                    break
                }
                
                self?.receiveMessage()
            }
        }
    }
    
    private func processCoinbaseMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        
        // Update last message time for health check
        DispatchQueue.main.async {
            self.lastMessageTime = Date()
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let type = json["type"] as? String ?? ""
                
                if type == "ticker",
                   let productId = json["product_id"] as? String,
                   let priceString = json["price"] as? String,
                   let price = Double(priceString),
                   cryptocurrencies[productId] != nil {
                    
                    let open24h = Double(json["open_24h"] as? String ?? "0") ?? price
                    let changePercent = open24h > 0 ? ((price - open24h) / open24h) * 100 : 0
                    let volume = Double(json["volume_24h"] as? String ?? "0") ?? 0
                    
                    DispatchQueue.main.async {
                        self.cryptocurrencies[productId]?.price = price
                        self.cryptocurrencies[productId]?.open24h = open24h
                        self.cryptocurrencies[productId]?.changePercent24h = changePercent
                        self.cryptocurrencies[productId]?.volume24h = volume
                        self.cryptocurrencies[productId]?.lastUpdate = Date()
                        self.updateUI()
                    }
                }
                else if type == "subscriptions" {
                    print("✅ Subscription confirmed")
                }
                else if type == "error" {
                    let errorMessage = json["message"] as? String ?? "Unknown error"
                    print("❌ Coinbase error: \(errorMessage)")
                }
            }
        } catch {
            print("Error parsing Coinbase JSON: \(error)")
        }
    }
    
    private func scheduleReconnect() {
        DispatchQueue.main.async {
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                print("Attempting to reconnect WebSocket...")
                self.connectToWebSocket()
            }
        }
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        updateStatusBarForSelectedCrypto()
        updateMenuPrices()
    }
    
    private func updateStatusBarForSelectedCrypto() {
        if selectedCryptos.isEmpty { selectedCryptos = ["BTC-USD"] }
        
        let entries: [String] = selectedCryptos.prefix(3).compactMap { symbol in
            guard let c = cryptocurrencies[symbol] else { return nil }
            let priceString = formatPrice(c.price)
            let changeString = formatPercentChange(c.changePercent24h)
            return "\(c.emoji) $\(priceString) \(changeString)"
        }

        if let button = statusItem?.button {
            button.title = entries.joined(separator: " | ")
        }

        if let menu = statusItem?.menu,
           let priceItem = menu.item(withTag: 100) {
            let summary = selectedCryptos.isEmpty ? "Selected: None" : "Selected: \(selectedCryptos.joined(separator: ", "))"
            priceItem.title = summary
        }
    }
    
    private func updateMenuPrices() {
        guard let menu = statusItem?.menu,
              let allCryptosItem = menu.item(withTitle: "All Cryptocurrencies"),
              let submenu = allCryptosItem.submenu else { return }
        
        // Only update checkmarks, not prices
        for item in submenu.items {
            if let symbol = item.representedObject as? String,
               let crypto = cryptocurrencies[symbol] {
                let isSelected = selectedCryptos.contains(symbol) ? " ✓" : ""
                item.title = "\(crypto.emoji) \(crypto.name) (\(crypto.baseCurrency))\(isSelected)"
            }
        }
    }

    private func formatPrice(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true

        let fractionDigits: Int
        let absolutePrice = abs(price)

        switch absolutePrice {
        case ..<0.01:
            fractionDigits = 8
        case ..<1:
            fractionDigits = 6
        case ..<10:
            fractionDigits = 4
        case ..<100:
            fractionDigits = 3
        case ..<10_000:
            fractionDigits = 2
        default:
            fractionDigits = 1
        }

        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits

        return formatter.string(from: NSNumber(value: price)) ?? String(format: "%.*f", fractionDigits, price)
    }
    
    private func formatPercentChange(_ change: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"
        
        let changeString = formatter.string(from: NSNumber(value: change)) ?? "0.00"
        return "(\(changeString)%)"
    }
}
