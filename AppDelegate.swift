import Cocoa
import Foundation

// Source identifiers
enum DataSource: String {
    case coinbase = "CB"
    case hyperliquidPerp = "HLP"   // Hyperliquid Perpetuals
    case hyperliquidSpot = "HLS"   // Hyperliquid Spot
    case hyperliquidHIP3 = "HLH"   // Hyperliquid HIP-3 (stocks, commodities, indices)
    case tradingView = "TV"        // TradingView (stocks)
}

struct CryptoCurrency {
    let symbol: String          // Full symbol with prefix (e.g., "CB:BTC-USD", "HLP:BTC", "HLH:xyz:TSLA")
    let rawSymbol: String       // Raw symbol for API (e.g., "BTC-USD", "BTC", "xyz:TSLA")
    let baseCurrency: String    // Base currency for display (e.g., "BTC", "TSLA")
    let name: String
    let emoji: String
    let source: DataSource
    var price: Double
    var open24h: Double
    var changePercent24h: Double
    var lastUpdate: Date
    
    init(symbol: String, rawSymbol: String, baseCurrency: String, name: String, emoji: String, source: DataSource) {
        self.symbol = symbol
        self.rawSymbol = rawSymbol
        self.baseCurrency = baseCurrency
        self.name = name
        self.emoji = emoji
        self.source = source
        self.price = 0.0
        self.open24h = 0.0
        self.changePercent24h = 0.0
        self.lastUpdate = Date()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, URLSessionWebSocketDelegate {
    
    var statusItem: NSStatusItem?
    
    // Coinbase WebSocket
    var coinbaseWebSocket: URLSessionWebSocketTask?
    var coinbaseSession: URLSession?
    var coinbaseConnected: Bool = false
    var coinbaseLastMessage: Date?
    var coinbaseReconnectScheduled: Bool = false
    var coinbaseLastReconnectAttempt: Date?
    
    // Hyperliquid WebSocket (serves perps and spot via allMids)
    var hyperliquidWebSocket: URLSessionWebSocketTask?
    var hyperliquidSession: URLSession?
    var hyperliquidConnected: Bool = false
    var hyperliquidLastMessage: Date?
    var hyperliquidReconnectScheduled: Bool = false
    var hyperliquidLastReconnectAttempt: Date?
    
    // HIP-3 WebSocket (serves stocks/commodities/indices via allMids with dex:"xyz")
    var hip3WebSocket: URLSessionWebSocketTask?
    var hip3Session: URLSession?
    var hip3Connected: Bool = false
    var hip3LastMessage: Date?
    var hip3ReconnectScheduled: Bool = false
    var hip3LastReconnectAttempt: Date?
    
    // TradingView WebSocket (stocks via real-time quotes)
    var tradingViewWebSocket: URLSessionWebSocketTask?
    var tradingViewSession: URLSession?
    var tradingViewConnected: Bool = false
    var tradingViewLastMessage: Date?
    var tradingViewReconnectScheduled: Bool = false
    var tradingViewLastReconnectAttempt: Date?
    var tradingViewQuoteSession: String = ""  // Session ID for quote subscriptions
    
    private let reconnectCooldown: TimeInterval = 3.0
    
    // All cryptocurrencies from all sources
    var coinbaseCryptos: [String: CryptoCurrency] = [:]
    var hyperliquidPerpCryptos: [String: CryptoCurrency] = [:]
    var hyperliquidSpotCryptos: [String: CryptoCurrency] = [:]
    var hyperliquidHIP3Cryptos: [String: CryptoCurrency] = [:]
    var tradingViewStocks: [String: CryptoCurrency] = [:]
    
    // Spot token index to name mapping
    var spotTokenNames: [Int: String] = [:]
    
    // Selected cryptos (with source prefix) - loaded from UserDefaults in init
    var selectedCryptos: [String] = []
    
    var healthCheckTimer: Timer?
    var midnightRefreshTimer: Timer?  // Bug #3: Refresh open24h after midnight
    
    private let healthCheckInterval: TimeInterval = 30
    private let staleConnectionThreshold: TimeInterval = 60
    
    // Bug #1 & #2: Track fetch completion to avoid race conditions
    private var coinbaseProductsLoaded = false
    private var hyperliquidPerpProductsLoaded = false
    private var hyperliquidSpotProductsLoaded = false
    private var hyperliquidHIP3ProductsLoaded = false
    private var tradingViewProductsLoaded = false
    
    // UserDefaults key for persistence (Bug #5)
    private let selectedCryptosKey = "selectedCryptos"
    
    // Computed: which sources have selected symbols
    private var hasCoinbaseSelection: Bool {
        selectedCryptos.contains { $0.hasPrefix("CB:") }
    }
    private var hasHyperliquidSelection: Bool {
        selectedCryptos.contains { $0.hasPrefix("HLP:") || $0.hasPrefix("HLS:") }
    }
    private var hasHIP3Selection: Bool {
        selectedCryptos.contains { $0.hasPrefix("HLH:") }
    }
    private var hasTradingViewSelection: Bool {
        selectedCryptos.contains { $0.hasPrefix("TV:") }
    }
    
    // Known crypto/asset names and emojis
    private let knownCryptos: [String: (name: String, emoji: String)] = [
        // Crypto
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
        "HYPE": ("Hyperliquid", "🔥"),
        "TAO": ("Bittensor", "🧠"),
        "ONDO": ("Ondo", "🏦"),
        "PENDLE": ("Pendle", "📈"),
        "TRX": ("TRON", "🔺"),
        "TON": ("Toncoin", "💎"),
        "RUNE": ("THORChain", "⚡"),
        "PURR": ("Purr", "🐱"),
        "HFUN": ("HyperFun", "🎉"),
        "JEFF": ("Jeff", "👤"),
        "USDC": ("USD Coin", "💵"),
        // HIP-3 Stocks
        "TSLA": ("Tesla", "🚗"),
        "NVDA": ("NVIDIA", "🎮"),
        "AAPL": ("Apple", "🍎"),
        "META": ("Meta", "📘"),
        "GOOGL": ("Google", "🔍"),
        "AMZN": ("Amazon", "📦"),
        "MSFT": ("Microsoft", "💻"),
        "AMD": ("AMD", "💻"),
        "COIN": ("Coinbase", "🪙"),
        "PLTR": ("Palantir", "🔮"),
        "HOOD": ("Robinhood", "🏹"),
        "INTC": ("Intel", "💾"),
        "GME": ("GameStop", "🎮"),
        "AMC": ("AMC", "🎬"),
        "MSTR": ("MicroStrategy", "📊"),
        // HIP-3 Commodities
        "GOLD": ("Gold", "🥇"),
        "SILVER": ("Silver", "🥈"),
        "OIL": ("Oil", "🛢️"),
        // HIP-3 Indices
        "XYZ100": ("HLP Index", "📈"),
        "SPY": ("S&P 500", "📊"),
        // Additional Stocks (TradingView)
        "GOOG": ("Alphabet", "🔍"),
        "BRK.A": ("Berkshire", "🏛️"),
        "BRK.B": ("Berkshire B", "🏛️"),
        "LLY": ("Eli Lilly", "💊"),
        "V": ("Visa", "💳"),
        "JPM": ("JPMorgan", "🏦"),
        "XOM": ("Exxon", "⛽"),
        "JNJ": ("J&J", "🏥"),
        "MA": ("Mastercard", "💳"),
        "ORCL": ("Oracle", "☁️"),
        "COST": ("Costco", "🛒"),
        "ABBV": ("AbbVie", "💊"),
        "BAC": ("Bank of America", "🏦"),
        "HD": ("Home Depot", "🏠"),
        "CVX": ("Chevron", "⛽"),
        "PG": ("Procter & Gamble", "🧴"),
        "NFLX": ("Netflix", "🎬"),
        "MU": ("Micron", "💾"),
        "GE": ("GE Aerospace", "✈️"),
        "KO": ("Coca-Cola", "🥤"),
        "CSCO": ("Cisco", "🌐"),
        "WMT": ("Walmart", "🛒"),
        "AVGO": ("Broadcom", "📡"),
        "DIS": ("Disney", "🏰"),
        "PYPL": ("PayPal", "💰"),
        "CRM": ("Salesforce", "☁️"),
        "ADBE": ("Adobe", "🎨"),
        "QCOM": ("Qualcomm", "📱"),
        "T": ("AT&T", "📞"),
        "VZ": ("Verizon", "📶"),
        "PFE": ("Pfizer", "💉"),
        "MRK": ("Merck", "💊"),
        "NKE": ("Nike", "👟"),
        "BA": ("Boeing", "✈️"),
        "UNH": ("UnitedHealth", "🏥"),
    ]
    
    // MARK: - App Lifecycle
    
    override init() {
        super.init()
        // Bug #5: Load persisted selections from UserDefaults
        if let saved = UserDefaults.standard.stringArray(forKey: selectedCryptosKey), !saved.isEmpty {
            selectedCryptos = saved
            print("📂 Loaded \(saved.count) saved selections: \(saved.joined(separator: ", "))")
        } else {
            selectedCryptos = ["CB:BTC-USD"]  // Default fallback
            print("📂 No saved selections, using default: CB:BTC-USD")
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("🚀 App launched successfully!")
        setupStatusBar()
        registerForWakeNotifications()
        startHealthCheckTimer()
        startMidnightRefreshTimer()  // Bug #3: Schedule daily refresh
        
        // Fetch products from all sources
        fetchCoinbaseProducts()
        fetchHyperliquidPerpProducts()
        fetchHyperliquidSpotProducts()
        fetchHyperliquidHIP3Products()
        fetchTradingViewStocks()
    }
    
    // Bug #5: Persist selections to UserDefaults
    private func saveSelectedCryptos() {
        UserDefaults.standard.set(selectedCryptos, forKey: selectedCryptosKey)
        print("💾 Saved selections: \(selectedCryptos.joined(separator: ", "))")
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        disconnectCoinbase()
        disconnectHyperliquid()
        disconnectHIP3()
        disconnectTradingView()
        healthCheckTimer?.invalidate()
        midnightRefreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    // Bug #3: Schedule refresh after midnight UTC to update open24h values
    private func startMidnightRefreshTimer() {
        midnightRefreshTimer?.invalidate()
        
        // Calculate time until next midnight UTC
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        
        let now = Date()
        if let tomorrow = utcCalendar.date(byAdding: .day, value: 1, to: now),
           let midnightUTC = utcCalendar.startOfDay(for: tomorrow).addingTimeInterval(60) as Date? {
            // Add 60 seconds buffer after midnight
            let timeUntilRefresh = midnightUTC.timeIntervalSince(now)
            
            print("🕐 Scheduled 24h data refresh in \(Int(timeUntilRefresh / 3600))h \(Int((timeUntilRefresh.truncatingRemainder(dividingBy: 3600)) / 60))m")
            
            midnightRefreshTimer = Timer.scheduledTimer(withTimeInterval: timeUntilRefresh, repeats: false) { [weak self] _ in
                self?.refreshOpen24hData()
            }
        }
    }
    
    // Bug #3: Refresh open24h data after midnight rollover
    private func refreshOpen24hData() {
        print("🔄 Midnight UTC passed - refreshing 24h price data...")
        
        // Re-fetch all products to get updated prevDayPx values
        fetchHyperliquidPerpProducts()
        fetchHyperliquidSpotProducts()
        fetchHyperliquidHIP3Products()
        
        // Schedule next refresh
        startMidnightRefreshTimer()
    }
    
    // MARK: - Auto Reconnect
    
    private func registerForWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil
        )
        print("📡 Registered for system wake notifications")
    }
    
    @objc private func systemDidWake(_ notification: Notification) {
        print("💤 System woke - reconnecting all active sources...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.forceReconnectAll()
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
        let now = Date()
        
        if hasCoinbaseSelection {
            let cbStale = coinbaseLastMessage.map { now.timeIntervalSince($0) > staleConnectionThreshold } ?? true
            if !coinbaseConnected || cbStale {
                print("🔴 Health check: Coinbase needs reconnect")
                reconnectCoinbase()
            } else {
                let ago = coinbaseLastMessage.map { Int(now.timeIntervalSince($0)) } ?? -1
                print("🟢 Health check: Coinbase OK (last msg \(ago)s ago)")
            }
        }
        
        if hasHyperliquidSelection {
            let hlStale = hyperliquidLastMessage.map { now.timeIntervalSince($0) > staleConnectionThreshold } ?? true
            if !hyperliquidConnected || hlStale {
                print("🔴 Health check: Hyperliquid needs reconnect")
                reconnectHyperliquid()
            } else {
                let ago = hyperliquidLastMessage.map { Int(now.timeIntervalSince($0)) } ?? -1
                print("🟢 Health check: Hyperliquid OK (last msg \(ago)s ago)")
            }
        }
        
        if hasHIP3Selection {
            let hip3Stale = hip3LastMessage.map { now.timeIntervalSince($0) > staleConnectionThreshold } ?? true
            if !hip3Connected || hip3Stale {
                print("🔴 Health check: HIP-3 needs reconnect")
                reconnectHIP3()
            } else {
                let ago = hip3LastMessage.map { Int(now.timeIntervalSince($0)) } ?? -1
                print("🟢 Health check: HIP-3 OK (last msg \(ago)s ago)")
            }
        }
        
        if hasTradingViewSelection {
            let tvStale = tradingViewLastMessage.map { now.timeIntervalSince($0) > staleConnectionThreshold } ?? true
            if !tradingViewConnected || tvStale {
                print("🔴 Health check: TradingView needs reconnect")
                reconnectTradingView()
            } else {
                let ago = tradingViewLastMessage.map { Int(now.timeIntervalSince($0)) } ?? -1
                print("🟢 Health check: TradingView OK (last msg \(ago)s ago)")
            }
        }
    }
    
    private func forceReconnectAll() {
        disconnectCoinbase()
        disconnectHyperliquid()
        disconnectHIP3()
        disconnectTradingView()
        
        if hasCoinbaseSelection {
            connectToCoinbase()
        }
        if hasHyperliquidSelection {
            connectToHyperliquid()
        }
        if hasHIP3Selection {
            connectToHIP3()
        }
        if hasTradingViewSelection {
            connectToTradingView()
        }
    }
    
    private func reconnectCoinbase() {
        if let lastAttempt = coinbaseLastReconnectAttempt,
           Date().timeIntervalSince(lastAttempt) < reconnectCooldown {
            return
        }
        disconnectCoinbase()
        connectToCoinbase()
    }
    
    private func reconnectHyperliquid() {
        if let lastAttempt = hyperliquidLastReconnectAttempt,
           Date().timeIntervalSince(lastAttempt) < reconnectCooldown {
            return
        }
        disconnectHyperliquid()
        connectToHyperliquid()
    }
    
    private func disconnectCoinbase() {
        coinbaseWebSocket?.cancel(with: .goingAway, reason: nil)
        coinbaseWebSocket = nil
        coinbaseSession?.invalidateAndCancel()
        coinbaseSession = nil
        coinbaseConnected = false
    }
    
    private func disconnectHyperliquid() {
        hyperliquidWebSocket?.cancel(with: .goingAway, reason: nil)
        hyperliquidWebSocket = nil
        hyperliquidSession?.invalidateAndCancel()
        hyperliquidSession = nil
        hyperliquidConnected = false
    }
    
    private func reconnectHIP3() {
        if let lastAttempt = hip3LastReconnectAttempt,
           Date().timeIntervalSince(lastAttempt) < reconnectCooldown {
            return
        }
        disconnectHIP3()
        connectToHIP3()
    }
    
    private func disconnectHIP3() {
        hip3WebSocket?.cancel(with: .goingAway, reason: nil)
        hip3WebSocket = nil
        hip3Session?.invalidateAndCancel()
        hip3Session = nil
        hip3Connected = false
    }
    
    private func reconnectTradingView() {
        if let lastAttempt = tradingViewLastReconnectAttempt,
           Date().timeIntervalSince(lastAttempt) < reconnectCooldown {
            return
        }
        disconnectTradingView()
        connectToTradingView()
    }
    
    private func disconnectTradingView() {
        tradingViewWebSocket?.cancel(with: .goingAway, reason: nil)
        tradingViewWebSocket = nil
        tradingViewSession?.invalidateAndCancel()
        tradingViewSession = nil
        tradingViewConnected = false
        tradingViewQuoteSession = ""
    }
    
    // MARK: - Status Bar Setup
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "₿ Loading..."
            button.target = self
            button.action = #selector(statusBarButtonClicked)
        }
        setupMenu()
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        
        // Connection status
        let statusHeader = NSMenuItem(title: "Connection Status:", action: nil, keyEquivalent: "")
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        
        if hasCoinbaseSelection {
            let cbStatus = coinbaseConnected ? "🟢 Connected" : "🔴 Disconnected"
            let cbItem = NSMenuItem(title: "  Coinbase: \(cbStatus)", action: nil, keyEquivalent: "")
            cbItem.isEnabled = false
            menu.addItem(cbItem)
        }
        
        if hasHyperliquidSelection {
            let hlStatus = hyperliquidConnected ? "🟢 Connected" : "🔴 Disconnected"
            let hlItem = NSMenuItem(title: "  HL Perps/Spot: \(hlStatus)", action: nil, keyEquivalent: "")
            hlItem.isEnabled = false
            menu.addItem(hlItem)
        }
        
        if hasHIP3Selection {
            let hip3Status = hip3Connected ? "🟢 Connected" : "🔴 Disconnected"
            let hip3Item = NSMenuItem(title: "  HL HIP-3: \(hip3Status)", action: nil, keyEquivalent: "")
            hip3Item.isEnabled = false
            menu.addItem(hip3Item)
        }
        
        if hasTradingViewSelection {
            let tvStatus = tradingViewConnected ? "🟢 Connected" : "🔴 Disconnected"
            let tvItem = NSMenuItem(title: "  TradingView: \(tvStatus)", action: nil, keyEquivalent: "")
            tvItem.isEnabled = false
            menu.addItem(tvItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Active tickers section
        let activeHeader = NSMenuItem(title: "Active Tickers:", action: nil, keyEquivalent: "")
        activeHeader.isEnabled = false
        menu.addItem(activeHeader)
        
        if selectedCryptos.isEmpty {
            let noneItem = NSMenuItem(title: "  None selected", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for symbol in selectedCryptos {
                if let crypto = getCrypto(symbol) {
                    let sourceLabel: String
                    switch crypto.source {
                    case .coinbase: sourceLabel = "CB"
                    case .hyperliquidPerp: sourceLabel = "HL-Perp"
                    case .hyperliquidSpot: sourceLabel = "HL-Spot"
                    case .hyperliquidHIP3: sourceLabel = "HL-HIP3"
                    case .tradingView: sourceLabel = "TV"
                    }
                    let item = NSMenuItem(
                        title: "  \(crypto.emoji) \(crypto.name) [\(sourceLabel)]",
                        action: #selector(toggleCryptocurrency(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = symbol
                    item.state = .on
                    if selectedCryptos.count == 1 {
                        item.isEnabled = false
                    }
                    menu.addItem(item)
                }
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Coinbase submenu
        let coinbaseItem = NSMenuItem(title: "Coinbase", action: nil, keyEquivalent: "")
        let coinbaseMenu = NSMenu()
        let sortedCB = coinbaseCryptos.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for crypto in sortedCB {
            let isSelected = selectedCryptos.contains(crypto.symbol)
            let item = NSMenuItem(
                title: "\(crypto.emoji) \(crypto.name) (\(crypto.baseCurrency))",
                action: #selector(toggleCryptocurrency(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = crypto.symbol
            item.state = isSelected ? .on : .off
            if isSelected && selectedCryptos.count == 1 { item.isEnabled = false }
            coinbaseMenu.addItem(item)
        }
        coinbaseItem.submenu = coinbaseMenu
        menu.addItem(coinbaseItem)
        
        // Hyperliquid Perps submenu
        let hlPerpItem = NSMenuItem(title: "Hyperliquid Perps", action: nil, keyEquivalent: "")
        let hlPerpMenu = NSMenu()
        let sortedHLP = hyperliquidPerpCryptos.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for crypto in sortedHLP {
            let isSelected = selectedCryptos.contains(crypto.symbol)
            let item = NSMenuItem(
                title: "\(crypto.emoji) \(crypto.name) (\(crypto.baseCurrency))",
                action: #selector(toggleCryptocurrency(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = crypto.symbol
            item.state = isSelected ? .on : .off
            if isSelected && selectedCryptos.count == 1 { item.isEnabled = false }
            hlPerpMenu.addItem(item)
        }
        hlPerpItem.submenu = hlPerpMenu
        menu.addItem(hlPerpItem)
        
        // Hyperliquid Spot submenu
        let hlSpotItem = NSMenuItem(title: "Hyperliquid Spot", action: nil, keyEquivalent: "")
        let hlSpotMenu = NSMenu()
        let sortedHLS = hyperliquidSpotCryptos.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for crypto in sortedHLS {
            let isSelected = selectedCryptos.contains(crypto.symbol)
            let item = NSMenuItem(
                title: "\(crypto.emoji) \(crypto.name) (\(crypto.baseCurrency))",
                action: #selector(toggleCryptocurrency(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = crypto.symbol
            item.state = isSelected ? .on : .off
            if isSelected && selectedCryptos.count == 1 { item.isEnabled = false }
            hlSpotMenu.addItem(item)
        }
        hlSpotItem.submenu = hlSpotMenu
        menu.addItem(hlSpotItem)
        
        // Hyperliquid HIP-3 submenu (stocks, commodities, indices)
        let hlHIP3Item = NSMenuItem(title: "Hyperliquid HIP-3 (Stocks/Indices)", action: nil, keyEquivalent: "")
        let hlHIP3Menu = NSMenu()
        let sortedHIP3 = hyperliquidHIP3Cryptos.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for crypto in sortedHIP3 {
            let isSelected = selectedCryptos.contains(crypto.symbol)
            let item = NSMenuItem(
                title: "\(crypto.emoji) \(crypto.name) (\(crypto.baseCurrency))",
                action: #selector(toggleCryptocurrency(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = crypto.symbol
            item.state = isSelected ? .on : .off
            if isSelected && selectedCryptos.count == 1 { item.isEnabled = false }
            hlHIP3Menu.addItem(item)
        }
        hlHIP3Item.submenu = hlHIP3Menu
        menu.addItem(hlHIP3Item)
        
        // TradingView Stocks submenu
        let tvStocksItem = NSMenuItem(title: "TradingView Stocks", action: nil, keyEquivalent: "")
        let tvStocksMenu = NSMenu()
        let sortedTV = tradingViewStocks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for stock in sortedTV {
            let isSelected = selectedCryptos.contains(stock.symbol)
            let item = NSMenuItem(
                title: "\(stock.emoji) \(stock.name) (\(stock.baseCurrency))",
                action: #selector(toggleCryptocurrency(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = stock.symbol
            item.state = isSelected ? .on : .off
            if isSelected && selectedCryptos.count == 1 { item.isEnabled = false }
            tvStocksMenu.addItem(item)
        }
        tvStocksItem.submenu = tvStocksMenu
        menu.addItem(tvStocksItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let reconnectItem = NSMenuItem(title: "Reconnect All", action: #selector(manualReconnectAll), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)
        
        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    private func getCrypto(_ symbol: String) -> CryptoCurrency? {
        return coinbaseCryptos[symbol] ?? hyperliquidPerpCryptos[symbol] ?? hyperliquidSpotCryptos[symbol] ?? hyperliquidHIP3Cryptos[symbol] ?? tradingViewStocks[symbol]
    }
    
    @objc func toggleCryptocurrency(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        
        let wasSelectedCB = hasCoinbaseSelection
        let wasSelectedHL = hasHyperliquidSelection
        let wasSelectedHIP3 = hasHIP3Selection
        let wasSelectedTV = hasTradingViewSelection
        
        if let idx = selectedCryptos.firstIndex(of: symbol) {
            if selectedCryptos.count <= 1 { return }
            selectedCryptos.remove(at: idx)
        } else {
            if selectedCryptos.count >= 3 {
                let alert = NSAlert()
                alert.messageText = "Selection limit reached"
                alert.informativeText = "You can select up to 3 currencies."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            selectedCryptos.append(symbol)
        }
        
        // Bug #5: Persist selection changes
        saveSelectedCryptos()
        
        setupMenu()
        updateStatusBar()
        
        let nowSelectedCB = hasCoinbaseSelection
        let nowSelectedHL = hasHyperliquidSelection
        let nowSelectedHIP3 = hasHIP3Selection
        
        // Handle Coinbase connection changes
        // Coinbase requires subscription per symbol, so reconnect if selection changed while connected
        if nowSelectedCB && !wasSelectedCB {
            // First Coinbase symbol selected - connect
            connectToCoinbase()
        } else if !nowSelectedCB && wasSelectedCB {
            // All Coinbase symbols deselected - disconnect
            disconnectCoinbase()
        } else if nowSelectedCB && coinbaseConnected {
            // Selection changed while connected - update subscription (reconnect to resubscribe)
            reconnectCoinbase()
        }
        
        // Handle Hyperliquid perps/spot connection changes
        // allMids broadcasts ALL prices, so only connect/disconnect when source first selected/deselected
        if nowSelectedHL && !wasSelectedHL {
            // First HL symbol selected - connect
            connectToHyperliquid()
        } else if !nowSelectedHL && wasSelectedHL {
            // All HL symbols deselected - disconnect
            disconnectHyperliquid()
        }
        // No reconnect needed when adding more HL symbols - allMids already sends all prices
        
        // Handle HIP-3 WebSocket connection changes
        // allMids with dex:xyz broadcasts ALL HIP-3 prices, so only connect/disconnect on first/last selection
        if nowSelectedHIP3 && !wasSelectedHIP3 {
            // First HIP-3 symbol selected - connect
            connectToHIP3()
        } else if !nowSelectedHIP3 && wasSelectedHIP3 {
            // All HIP-3 symbols deselected - disconnect
            disconnectHIP3()
        }
        // No reconnect needed when adding more HIP-3 symbols - allMids already sends all prices
        
        let nowSelectedTV = hasTradingViewSelection
        
        // Handle TradingView WebSocket connection changes
        // TradingView requires per-symbol subscription, so reconnect when selection changes
        if nowSelectedTV && !wasSelectedTV {
            // First TV symbol selected - connect
            connectToTradingView()
        } else if !nowSelectedTV && wasSelectedTV {
            // All TV symbols deselected - disconnect
            disconnectTradingView()
        } else if nowSelectedTV && tradingViewConnected {
            // Selection changed while connected - resubscribe (reconnect)
            reconnectTradingView()
        }
    }
    
    @objc func statusBarButtonClicked() {}
    
    @objc func manualReconnectAll() {
        print("🔄 Manual reconnect requested")
        
        // Bug #4: Actually disconnect first before reconnecting
        disconnectCoinbase()
        disconnectHyperliquid()
        disconnectHIP3()
        disconnectTradingView()
        
        // Reset loaded flags to allow fresh connections
        coinbaseProductsLoaded = false
        hyperliquidPerpProductsLoaded = false
        hyperliquidSpotProductsLoaded = false
        hyperliquidHIP3ProductsLoaded = false
        tradingViewProductsLoaded = false
        
        // Now fetch products (which will reconnect WebSockets)
        fetchCoinbaseProducts()
        fetchHyperliquidPerpProducts()
        fetchHyperliquidSpotProducts()
        fetchHyperliquidHIP3Products()
        fetchTradingViewStocks()
    }
    
    @objc func showAbout() {
        let cbStatus = coinbaseConnected ? "Connected" : "Disconnected"
        let hlStatus = hyperliquidConnected ? "Connected" : "Disconnected"
        let hip3Status = hip3Connected ? "Connected" : "Disconnected"
        let tvStatus = tradingViewConnected ? "Connected" : "Disconnected"
        
        let alert = NSAlert()
        alert.messageText = "Crypto Price Monitor"
        alert.informativeText = """
        Real-time cryptocurrency and stock prices in your status bar.
        
        Data Sources:
        • Coinbase: \(coinbaseCryptos.count) pairs (\(cbStatus))
        • HL Perps: \(hyperliquidPerpCryptos.count) assets (\(hlStatus))
        • HL Spot: \(hyperliquidSpotCryptos.count) pairs (\(hlStatus))
        • HL HIP-3: \(hyperliquidHIP3Cryptos.count) assets (\(hip3Status))
        • TradingView: \(tradingViewStocks.count) stocks (\(tvStatus))
        
        Select up to 3 tickers from any source.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Coinbase API
    
    private func fetchCoinbaseProducts() {
        guard let url = URL(string: "https://api.exchange.coinbase.com/products") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        print("📥 Fetching Coinbase products...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                print("❌ Coinbase products fetch error: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }
            
            do {
                if let products = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    let usdProducts = products.filter {
                        ($0["quote_currency"] as? String) == "USD" && ($0["status"] as? String) == "online"
                    }
                    
                    var cryptos: [String: CryptoCurrency] = [:]
                    for product in usdProducts {
                        guard let rawSymbol = product["id"] as? String,
                              let baseCurrency = product["base_currency"] as? String else { continue }
                        
                        let symbol = "CB:\(rawSymbol)"
                        let info = self.knownCryptos[baseCurrency]
                        let name = info?.name ?? baseCurrency
                        let emoji = info?.emoji ?? "💰"
                        
                        cryptos[symbol] = CryptoCurrency(
                            symbol: symbol, rawSymbol: rawSymbol, baseCurrency: baseCurrency,
                            name: name, emoji: emoji, source: .coinbase
                        )
                    }
                    
                    print("✅ Loaded \(cryptos.count) Coinbase products")
                    
                    DispatchQueue.main.async {
                        self.coinbaseCryptos = cryptos
                        self.coinbaseProductsLoaded = true
                        self.onProductsLoaded()  // Bug #1 & #2: Centralized connection logic
                    }
                }
            } catch {
                print("❌ Error parsing Coinbase products: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Hyperliquid Perp API
    
    private func fetchHyperliquidPerpProducts() {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Use metaAndAssetCtxs to get both metadata and 24h price data
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "metaAndAssetCtxs"])
        
        print("📥 Fetching Hyperliquid Perp products...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                print("❌ HL Perp products fetch error: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }
            
            do {
                // metaAndAssetCtxs returns [meta, assetCtxs] array
                if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                   json.count >= 2,
                   let meta = json[0] as? [String: Any],
                   let universe = meta["universe"] as? [[String: Any]],
                   let assetCtxs = json[1] as? [[String: Any]] {
                    
                    var cryptos: [String: CryptoCurrency] = [:]
                    for (index, asset) in universe.enumerated() {
                        guard let rawSymbol = asset["name"] as? String else { continue }
                        if asset["isDelisted"] as? Bool == true { continue }
                        
                        let symbol = "HLP:\(rawSymbol)"
                        let info = self.knownCryptos[rawSymbol]
                        let name = info?.name ?? rawSymbol
                        let emoji = info?.emoji ?? "📈"
                        
                        var crypto = CryptoCurrency(
                            symbol: symbol, rawSymbol: rawSymbol, baseCurrency: rawSymbol,
                            name: name, emoji: emoji, source: .hyperliquidPerp
                        )
                        
                        // Get 24h price data from assetCtxs
                        if index < assetCtxs.count {
                            let ctx = assetCtxs[index]
                            if let prevDayPxStr = ctx["prevDayPx"] as? String,
                               let prevDayPx = Double(prevDayPxStr) {
                                crypto.open24h = prevDayPx
                            }
                            if let markPxStr = ctx["markPx"] as? String,
                               let markPx = Double(markPxStr) {
                                crypto.price = markPx
                                if crypto.open24h > 0 {
                                    crypto.changePercent24h = ((markPx - crypto.open24h) / crypto.open24h) * 100
                                }
                            }
                        }
                        
                        cryptos[symbol] = crypto
                    }
                    
                    print("✅ Loaded \(cryptos.count) HL Perp products with 24h data")
                    
                    DispatchQueue.main.async {
                        self.hyperliquidPerpCryptos = cryptos
                        self.hyperliquidPerpProductsLoaded = true
                        self.onProductsLoaded()  // Bug #1 & #2: Centralized connection logic
                    }
                }
            } catch {
                print("❌ Error parsing HL Perp products: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Hyperliquid Spot API
    
    private func fetchHyperliquidSpotProducts() {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Use spotMetaAndAssetCtxs to get both metadata and 24h price data
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "spotMetaAndAssetCtxs"])
        
        print("📥 Fetching Hyperliquid Spot products...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                print("❌ HL Spot products fetch error: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }
            
            do {
                // spotMetaAndAssetCtxs returns [spotMeta, assetCtxs] array
                if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                   json.count >= 2,
                   let spotMeta = json[0] as? [String: Any],
                   let universe = spotMeta["universe"] as? [[String: Any]],
                   let tokens = spotMeta["tokens"] as? [[String: Any]],
                   let assetCtxs = json[1] as? [[String: Any]] {
                    
                    var tokenNames: [Int: String] = [:]
                    for token in tokens {
                        if let index = token["index"] as? Int, let name = token["name"] as? String {
                            tokenNames[index] = name
                        }
                    }
                    
                    // Build a map of coin name to asset context for quick lookup
                    var ctxByCoin: [String: [String: Any]] = [:]
                    for ctx in assetCtxs {
                        if let coin = ctx["coin"] as? String {
                            ctxByCoin[coin] = ctx
                        }
                    }
                    
                    var cryptos: [String: CryptoCurrency] = [:]
                    for pair in universe {
                        guard let pairName = pair["name"] as? String,
                              let tokenIndices = pair["tokens"] as? [Int],
                              tokenIndices.count >= 2 else { continue }
                        
                        let baseTokenName = tokenNames[tokenIndices[0]] ?? "Unknown"
                        let quoteTokenName = tokenNames[tokenIndices[1]] ?? "USD"
                        
                        let rawSymbol = pairName
                        let symbol = "HLS:\(rawSymbol)"
                        let displayName = pairName.hasPrefix("@") ? "\(baseTokenName)/\(quoteTokenName)" : pairName
                        
                        let info = self.knownCryptos[baseTokenName]
                        let name = info?.name ?? baseTokenName
                        let emoji = info?.emoji ?? "🪙"
                        
                        var crypto = CryptoCurrency(
                            symbol: symbol, rawSymbol: rawSymbol, baseCurrency: displayName,
                            name: name, emoji: emoji, source: .hyperliquidSpot
                        )
                        
                        // Get 24h price data from assetCtxs (matched by coin name)
                        if let ctx = ctxByCoin[pairName] {
                            if let prevDayPxStr = ctx["prevDayPx"] as? String,
                               let prevDayPx = Double(prevDayPxStr) {
                                crypto.open24h = prevDayPx
                            }
                            if let markPxStr = ctx["markPx"] as? String,
                               let markPx = Double(markPxStr) {
                                crypto.price = markPx
                                if crypto.open24h > 0 {
                                    crypto.changePercent24h = ((markPx - crypto.open24h) / crypto.open24h) * 100
                                }
                            }
                        }
                        
                        cryptos[symbol] = crypto
                    }
                    
                    print("✅ Loaded \(cryptos.count) HL Spot products with 24h data")
                    
                    DispatchQueue.main.async {
                        self.spotTokenNames = tokenNames  // Thread-safe: set on main thread
                        self.hyperliquidSpotCryptos = cryptos
                        self.hyperliquidSpotProductsLoaded = true
                        self.onProductsLoaded()  // Bug #1 & #2: Centralized connection logic
                    }
                }
            } catch {
                print("❌ Error parsing HL Spot products: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Hyperliquid HIP-3 API (Stocks, Commodities, Indices)
    
    private func fetchHyperliquidHIP3Products() {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Use metaAndAssetCtxs with dex:xyz to get both metadata and 24h price data
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "metaAndAssetCtxs", "dex": "xyz"])
        
        print("📥 Fetching Hyperliquid HIP-3 products...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                print("❌ HL HIP-3 products fetch error: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }
            
            do {
                // metaAndAssetCtxs returns [meta, assetCtxs] array
                if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                   json.count >= 2,
                   let meta = json[0] as? [String: Any],
                   let universe = meta["universe"] as? [[String: Any]],
                   let assetCtxs = json[1] as? [[String: Any]] {
                    
                    var cryptos: [String: CryptoCurrency] = [:]
                    for (index, asset) in universe.enumerated() {
                        guard let rawSymbol = asset["name"] as? String else { continue }
                        if asset["isDelisted"] as? Bool == true { continue }
                        
                        // Raw symbol is like "xyz:TSLA", strip prefix for display
                        let displaySymbol = rawSymbol.replacingOccurrences(of: "xyz:", with: "")
                        let symbol = "HLH:\(rawSymbol)"
                        
                        let info = self.knownCryptos[displaySymbol]
                        let name = info?.name ?? displaySymbol
                        let emoji = info?.emoji ?? "📊"
                        
                        var crypto = CryptoCurrency(
                            symbol: symbol, rawSymbol: rawSymbol, baseCurrency: displaySymbol,
                            name: name, emoji: emoji, source: .hyperliquidHIP3
                        )
                        
                        // Get 24h price data from assetCtxs
                        if index < assetCtxs.count {
                            let ctx = assetCtxs[index]
                            if let prevDayPxStr = ctx["prevDayPx"] as? String,
                               let prevDayPx = Double(prevDayPxStr) {
                                crypto.open24h = prevDayPx
                            }
                            if let markPxStr = ctx["markPx"] as? String,
                               let markPx = Double(markPxStr) {
                                crypto.price = markPx
                                if crypto.open24h > 0 {
                                    crypto.changePercent24h = ((markPx - crypto.open24h) / crypto.open24h) * 100
                                }
                            }
                        }
                        
                        cryptos[symbol] = crypto
                    }
                    
                    print("✅ Loaded \(cryptos.count) HL HIP-3 products with 24h data")
                    
                    DispatchQueue.main.async {
                        self.hyperliquidHIP3Cryptos = cryptos
                        self.hyperliquidHIP3ProductsLoaded = true
                        self.onProductsLoaded()  // Bug #1 & #2: Centralized connection logic
                    }
                }
            } catch {
                print("❌ Error parsing HL HIP-3 products: \(error)")
            }
        }.resume()
    }
    
    // MARK: - TradingView Scanner API (Stocks)
    
    private func fetchTradingViewStocks() {
        guard let url = URL(string: "https://scanner.tradingview.com/america/scan") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Query top 100 US stocks by market cap from NYSE and NASDAQ
        // Fields: name, close, description, exchange, change (%)
        let payload: [String: Any] = [
            "columns": ["name", "close", "description", "exchange", "change"],
            "filter": [
                ["left": "type", "operation": "equal", "right": "stock"],
                ["left": "is_primary", "operation": "equal", "right": true],
                ["left": "exchange", "operation": "in_range", "right": ["NYSE", "NASDAQ"]]
            ],
            "sort": ["sortBy": "market_cap_basic", "sortOrder": "desc"],
            "range": [0, 100]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        print("📥 Fetching TradingView stocks...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                print("❌ TradingView stocks fetch error: \(error.localizedDescription)")
                // Still mark as loaded to not block other sources
                DispatchQueue.main.async {
                    self.tradingViewProductsLoaded = true
                    self.onProductsLoaded()
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    self.tradingViewProductsLoaded = true
                    self.onProductsLoaded()
                }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let stocks = json["data"] as? [[String: Any]] {
                    
                    var tvStocks: [String: CryptoCurrency] = [:]
                    
                    for stock in stocks {
                        guard let fullSymbol = stock["s"] as? String,  // e.g., "NASDAQ:AAPL"
                              let values = stock["d"] as? [Any],
                              values.count >= 5 else { continue }
                        
                        // Parse values: [name, close, description, exchange, change]
                        let ticker = values[0] as? String ?? ""
                        let price = values[1] as? Double ?? 0
                        let description = values[2] as? String ?? ticker
                        // values[3] = exchange (unused)
                        let changePercent = values[4] as? Double ?? 0
                        // Calculate prev close from price and change percent
                        let prevClose = changePercent != 0 ? price / (1 + changePercent / 100) : price
                        
                        // Symbol format: TV:NASDAQ:AAPL
                        let symbol = "TV:\(fullSymbol)"
                        
                        let info = self.knownCryptos[ticker]
                        let name = info?.name ?? description
                        let emoji = info?.emoji ?? "📈"
                        
                        var crypto = CryptoCurrency(
                            symbol: symbol,
                            rawSymbol: fullSymbol,  // NASDAQ:AAPL (for WebSocket)
                            baseCurrency: ticker,    // AAPL (for display)
                            name: name,
                            emoji: emoji,
                            source: .tradingView
                        )
                        crypto.price = price
                        crypto.open24h = prevClose
                        crypto.changePercent24h = changePercent
                        
                        tvStocks[symbol] = crypto
                    }
                    
                    print("✅ Loaded \(tvStocks.count) TradingView stocks")
                    
                    DispatchQueue.main.async {
                        self.tradingViewStocks = tvStocks
                        self.tradingViewProductsLoaded = true
                        self.onProductsLoaded()
                    }
                }
            } catch {
                print("❌ Error parsing TradingView stocks: \(error)")
                DispatchQueue.main.async {
                    self.tradingViewProductsLoaded = true
                    self.onProductsLoaded()
                }
            }
        }.resume()
    }
    
    // Bug #1 & #2: Centralized handler called after each product fetch completes
    private func onProductsLoaded() {
        // Always update menu with latest data
        setupMenu()
        
        // Check if ALL products are loaded before validating selections
        let allLoaded = coinbaseProductsLoaded && hyperliquidPerpProductsLoaded && 
                        hyperliquidSpotProductsLoaded && hyperliquidHIP3ProductsLoaded &&
                        tradingViewProductsLoaded
        
        if allLoaded {
            print("✅ All products loaded - validating selections and connecting")
            validateSelectedCryptos()
            
            // Connect to each source only ONCE after all products loaded
            if hasCoinbaseSelection && !coinbaseConnected {
                connectToCoinbase()
            }
            // Bug #1: Only connect HL once (not from both Perp and Spot handlers)
            if hasHyperliquidSelection && !hyperliquidConnected {
                connectToHyperliquid()
            }
            if hasHIP3Selection && !hip3Connected {
                connectToHIP3()
            }
            if hasTradingViewSelection && !tradingViewConnected {
                connectToTradingView()
            }
        } else {
            // Partial load - connect sources that are ready and selected
            // But DON'T validate selections yet (Bug #2)
            if coinbaseProductsLoaded && hasCoinbaseSelection && !coinbaseConnected {
                connectToCoinbase()
            }
            // For HL, wait until BOTH perp and spot are loaded (Bug #1)
            if hyperliquidPerpProductsLoaded && hyperliquidSpotProductsLoaded && 
               hasHyperliquidSelection && !hyperliquidConnected {
                connectToHyperliquid()
            }
            if hyperliquidHIP3ProductsLoaded && hasHIP3Selection && !hip3Connected {
                connectToHIP3()
            }
            if tradingViewProductsLoaded && hasTradingViewSelection && !tradingViewConnected {
                connectToTradingView()
            }
        }
    }
    
    private func validateSelectedCryptos() {
        let originalCount = selectedCryptos.count
        selectedCryptos = selectedCryptos.filter { getCrypto($0) != nil }
        
        if selectedCryptos.count != originalCount {
            print("⚠️ Removed \(originalCount - selectedCryptos.count) invalid selections")
            saveSelectedCryptos()  // Bug #5: Persist the cleaned up selections
        }
        
        if selectedCryptos.isEmpty {
            if coinbaseCryptos["CB:BTC-USD"] != nil {
                selectedCryptos = ["CB:BTC-USD"]
            } else if hyperliquidPerpCryptos["HLP:BTC"] != nil {
                selectedCryptos = ["HLP:BTC"]
            }
            saveSelectedCryptos()
        }
        
        setupMenu()
        updateStatusBar()
    }
    
    // MARK: - Coinbase WebSocket
    
    private func connectToCoinbase() {
        guard hasCoinbaseSelection else { return }
        coinbaseLastReconnectAttempt = Date()
        disconnectCoinbase()
        
        guard let url = URL(string: "wss://ws-feed.exchange.coinbase.com") else { return }
        
        let config = URLSessionConfiguration.default
        coinbaseSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        coinbaseWebSocket = coinbaseSession?.webSocketTask(with: url)
        coinbaseWebSocket?.resume()
        
        print("🔌 Connecting to Coinbase WebSocket...")
    }
    
    private func sendCoinbaseSubscription() {
        let cbSymbols = selectedCryptos.compactMap { symbol -> String? in
            guard let crypto = coinbaseCryptos[symbol] else { return nil }
            return crypto.rawSymbol
        }
        guard !cbSymbols.isEmpty else { return }
        
        let msg: [String: Any] = ["type": "subscribe", "product_ids": cbSymbols, "channels": ["ticker"]]
        
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            coinbaseWebSocket?.send(.string(str)) { [weak self] error in
                // Bug #6: Handle send errors
                if let error = error {
                    print("❌ Coinbase subscription send failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self?.coinbaseConnected = false
                        self?.scheduleCoinbaseReconnect()
                    }
                } else {
                    print("📨 Coinbase subscribed: \(cbSymbols.joined(separator: ", "))")
                }
            }
        }
    }
    
    private func receiveCoinbaseMessage() {
        coinbaseWebSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self.coinbaseConnected = false
                    self.setupMenu()
                    self.scheduleCoinbaseReconnect()
                }
            case .success(let message):
                if case .string(let text) = message { self.processCoinbaseMessage(text) }
                if self.coinbaseWebSocket != nil { self.receiveCoinbaseMessage() }
            }
        }
    }
    
    private func processCoinbaseMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        DispatchQueue.main.async { self.coinbaseLastMessage = Date() }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let type = json["type"] as? String ?? ""
                if type == "ticker",
                   let rawSymbol = json["product_id"] as? String,
                   let priceStr = json["price"] as? String,
                   let price = Double(priceStr) {
                    
                    let symbol = "CB:\(rawSymbol)"
                    let open24h = Double(json["open_24h"] as? String ?? "0") ?? price
                    let change = open24h > 0 ? ((price - open24h) / open24h) * 100 : 0
                    
                    DispatchQueue.main.async {
                        self.coinbaseCryptos[symbol]?.price = price
                        self.coinbaseCryptos[symbol]?.open24h = open24h
                        self.coinbaseCryptos[symbol]?.changePercent24h = change
                        self.coinbaseCryptos[symbol]?.lastUpdate = Date()
                        self.updateStatusBar()
                    }
                }
            }
        } catch {}
    }
    
    private func scheduleCoinbaseReconnect() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.scheduleCoinbaseReconnect() }
            return
        }
        guard hasCoinbaseSelection, !coinbaseReconnectScheduled else { return }
        coinbaseReconnectScheduled = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.coinbaseReconnectScheduled = false
            guard self.hasCoinbaseSelection, !self.coinbaseConnected else { return }
            self.connectToCoinbase()
        }
    }
    
    // MARK: - Hyperliquid WebSocket (Perps + Spot via allMids)
    
    private func connectToHyperliquid() {
        guard hasHyperliquidSelection else { return }
        hyperliquidLastReconnectAttempt = Date()
        disconnectHyperliquid()
        
        guard let url = URL(string: "wss://api.hyperliquid.xyz/ws") else { return }
        
        let config = URLSessionConfiguration.default
        hyperliquidSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        hyperliquidWebSocket = hyperliquidSession?.webSocketTask(with: url)
        hyperliquidWebSocket?.resume()
        
        print("🔌 Connecting to Hyperliquid WebSocket...")
    }
    
    private func sendHyperliquidSubscription() {
        let msg = "{\"method\":\"subscribe\",\"subscription\":{\"type\":\"allMids\"}}"
        hyperliquidWebSocket?.send(.string(msg)) { [weak self] error in
            // Bug #6: Handle send errors
            if let error = error {
                print("❌ Hyperliquid subscription send failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.hyperliquidConnected = false
                    self?.scheduleHyperliquidReconnect()
                }
            } else {
                print("📨 Hyperliquid subscribed to allMids")
            }
        }
    }
    
    private func receiveHyperliquidMessage() {
        hyperliquidWebSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self.hyperliquidConnected = false
                    self.setupMenu()
                    self.scheduleHyperliquidReconnect()
                }
            case .success(let message):
                if case .string(let text) = message { self.processHyperliquidMessage(text) }
                if self.hyperliquidWebSocket != nil { self.receiveHyperliquidMessage() }
            }
        }
    }
    
    private func processHyperliquidMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        DispatchQueue.main.async { self.hyperliquidLastMessage = Date() }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let channel = json["channel"] as? String ?? ""
                
                if channel == "allMids",
                   let midsData = json["data"] as? [String: Any],
                   let mids = midsData["mids"] as? [String: String] {
                    
                    DispatchQueue.main.async {
                        for (rawSymbol, priceStr) in mids {
                            if let price = Double(priceStr) {
                                if rawSymbol.hasPrefix("@") || rawSymbol.contains("/") {
                                    // Spot asset
                                    let symbol = "HLS:\(rawSymbol)"
                                    if var crypto = self.hyperliquidSpotCryptos[symbol] {
                                        crypto.price = price
                                        crypto.lastUpdate = Date()
                                        // Recalculate 24h change using stored open24h
                                        if crypto.open24h > 0 {
                                            crypto.changePercent24h = ((price - crypto.open24h) / crypto.open24h) * 100
                                        }
                                        self.hyperliquidSpotCryptos[symbol] = crypto
                                    }
                                } else {
                                    // Perp asset
                                    let symbol = "HLP:\(rawSymbol)"
                                    if var crypto = self.hyperliquidPerpCryptos[symbol] {
                                        crypto.price = price
                                        crypto.lastUpdate = Date()
                                        // Recalculate 24h change using stored open24h
                                        if crypto.open24h > 0 {
                                            crypto.changePercent24h = ((price - crypto.open24h) / crypto.open24h) * 100
                                        }
                                        self.hyperliquidPerpCryptos[symbol] = crypto
                                    }
                                }
                            }
                        }
                        self.updateStatusBar()
                    }
                }
            }
        } catch {}
    }
    
    private func scheduleHyperliquidReconnect() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.scheduleHyperliquidReconnect() }
            return
        }
        guard hasHyperliquidSelection, !hyperliquidReconnectScheduled else { return }
        hyperliquidReconnectScheduled = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.hyperliquidReconnectScheduled = false
            guard self.hasHyperliquidSelection, !self.hyperliquidConnected else { return }
            self.connectToHyperliquid()
        }
    }
    
    // MARK: - HIP-3 WebSocket (allMids with dex:"xyz" for stocks/commodities/indices)
    
    private func connectToHIP3() {
        guard hasHIP3Selection else { return }
        hip3LastReconnectAttempt = Date()
        disconnectHIP3()
        
        guard let url = URL(string: "wss://api.hyperliquid.xyz/ws") else { return }
        
        let config = URLSessionConfiguration.default
        hip3Session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        hip3WebSocket = hip3Session?.webSocketTask(with: url)
        hip3WebSocket?.resume()
        
        print("🔌 Connecting to HIP-3 WebSocket...")
    }
    
    private func sendHIP3Subscription() {
        // Subscribe to allMids with dex:"xyz" for HIP-3 assets (stocks, commodities, indices)
        let msg = "{\"method\":\"subscribe\",\"subscription\":{\"type\":\"allMids\",\"dex\":\"xyz\"}}"
        hip3WebSocket?.send(.string(msg)) { [weak self] error in
            // Bug #6: Handle send errors
            if let error = error {
                print("❌ HIP-3 subscription send failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.hip3Connected = false
                    self?.scheduleHIP3Reconnect()
                }
            } else {
                print("📨 HIP-3 subscribed to allMids (dex:xyz)")
            }
        }
    }
    
    private func receiveHIP3Message() {
        hip3WebSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self.hip3Connected = false
                    self.setupMenu()
                    self.scheduleHIP3Reconnect()
                }
            case .success(let message):
                if case .string(let text) = message { self.processHIP3Message(text) }
                if self.hip3WebSocket != nil { self.receiveHIP3Message() }
            }
        }
    }
    
    private func processHIP3Message(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        DispatchQueue.main.async { self.hip3LastMessage = Date() }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let channel = json["channel"] as? String ?? ""
                
                // HIP-3 allMids response has dex:"xyz" in data
                if channel == "allMids",
                   let midsData = json["data"] as? [String: Any],
                   let mids = midsData["mids"] as? [String: String] {
                    
                    DispatchQueue.main.async {
                        for (rawSymbol, priceStr) in mids {
                            // HIP-3 symbols are like "xyz:TSLA", "xyz:GOLD", etc.
                            if let price = Double(priceStr) {
                                let symbol = "HLH:\(rawSymbol)"
                                if var crypto = self.hyperliquidHIP3Cryptos[symbol] {
                                    crypto.price = price
                                    crypto.lastUpdate = Date()
                                    // Recalculate 24h change using stored open24h
                                    if crypto.open24h > 0 {
                                        crypto.changePercent24h = ((price - crypto.open24h) / crypto.open24h) * 100
                                    }
                                    self.hyperliquidHIP3Cryptos[symbol] = crypto
                                }
                            }
                        }
                        self.updateStatusBar()
                    }
                }
            }
        } catch {}
    }
    
    private func scheduleHIP3Reconnect() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.scheduleHIP3Reconnect() }
            return
        }
        guard hasHIP3Selection, !hip3ReconnectScheduled else { return }
        hip3ReconnectScheduled = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.hip3ReconnectScheduled = false
            guard self.hasHIP3Selection, !self.hip3Connected else { return }
            self.connectToHIP3()
        }
    }
    
    // MARK: - TradingView WebSocket (real-time stock quotes)
    
    private func connectToTradingView() {
        guard hasTradingViewSelection else { return }
        tradingViewLastReconnectAttempt = Date()
        disconnectTradingView()
        
        guard let url = URL(string: "wss://data.tradingview.com/socket.io/websocket") else { return }
        
        let config = URLSessionConfiguration.default
        tradingViewSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        tradingViewWebSocket = tradingViewSession?.webSocketTask(with: url)
        tradingViewWebSocket?.resume()
        
        print("🔌 Connecting to TradingView WebSocket...")
    }
    
    // Generate a random session ID for TradingView
    private func generateTradingViewSessionId() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "qs_" + String((0..<12).map { _ in chars.randomElement()! })
    }
    
    // Send a TradingView formatted message (~m~{length}~m~{json})
    private func sendTradingViewMessage(_ function: String, _ params: [Any]) {
        let payload: [String: Any] = ["m": function, "p": params]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        
        let message = "~m~\(jsonStr.count)~m~\(jsonStr)"
        tradingViewWebSocket?.send(.string(message)) { [weak self] error in
            if let error = error {
                print("❌ TradingView send error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.tradingViewConnected = false
                    self?.scheduleTradingViewReconnect()
                }
            }
        }
    }
    
    private func sendTradingViewSubscription() {
        // Generate session ID
        tradingViewQuoteSession = generateTradingViewSessionId()
        
        // Get symbols to subscribe to
        let tvSymbols = selectedCryptos.compactMap { symbol -> String? in
            guard let stock = tradingViewStocks[symbol] else { return nil }
            return stock.rawSymbol  // e.g., "NASDAQ:AAPL"
        }
        
        guard !tvSymbols.isEmpty else {
            print("⚠️ TradingView: No symbols to subscribe to")
            return
        }
        
        // Auth with public token
        sendTradingViewMessage("set_auth_token", ["unauthorized_user_token"])
        
        // Create quote session
        sendTradingViewMessage("quote_create_session", [tradingViewQuoteSession])
        
        // Set fields we want to receive
        // lp=last price, ch=change, chp=change percent, volume, open_price, high_price, low_price
        sendTradingViewMessage("quote_set_fields", [
            tradingViewQuoteSession,
            "lp", "ch", "chp", "volume", "open_price", "high_price", "low_price"
        ])
        
        // Subscribe to symbols with slight delay to ensure session is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.tradingViewConnected else { return }
            for tvSymbol in tvSymbols {
                self.sendTradingViewMessage("quote_add_symbols", [self.tradingViewQuoteSession, tvSymbol])
            }
            print("📨 TradingView subscribed to \(tvSymbols.count) symbols: \(tvSymbols.joined(separator: ", "))")
        }
    }
    
    private func receiveTradingViewMessage() {
        tradingViewWebSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("❌ TradingView receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.tradingViewConnected = false
                    self.setupMenu()
                    self.scheduleTradingViewReconnect()
                }
            case .success(let message):
                if case .string(let text) = message {
                    self.processTradingViewMessage(text)
                }
                // Continue receiving if still connected
                if self.tradingViewWebSocket != nil && self.tradingViewConnected {
                    self.receiveTradingViewMessage()
                }
            }
        }
    }
    
    // Parse TradingView's ~m~ framed messages
    private func parseTradingViewMessages(_ raw: String) -> [String] {
        var messages: [String] = []
        var index = raw.startIndex
        
        while index < raw.endIndex {
            guard raw[index...].hasPrefix("~m~") else { break }
            index = raw.index(index, offsetBy: 3)
            
            // Find end of length
            guard let tildeRange = raw[index...].range(of: "~m~") else { break }
            let lengthStr = String(raw[index..<tildeRange.lowerBound])
            guard let length = Int(lengthStr) else { break }
            
            index = raw.index(tildeRange.upperBound, offsetBy: 0)
            let endIndex = raw.index(index, offsetBy: length, limitedBy: raw.endIndex) ?? raw.endIndex
            let msg = String(raw[index..<endIndex])
            messages.append(msg)
            index = endIndex
        }
        
        return messages
    }
    
    private func processTradingViewMessage(_ rawMessage: String) {
        DispatchQueue.main.async { self.tradingViewLastMessage = Date() }
        
        let messages = parseTradingViewMessages(rawMessage)
        
        for msg in messages {
            // Handle heartbeat
            if msg.hasPrefix("~h~") {
                // Echo heartbeat back
                tradingViewWebSocket?.send(.string(rawMessage)) { _ in }
                continue
            }
            
            // Parse JSON messages
            guard msg.hasPrefix("{"),
                  let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            let m = json["m"] as? String ?? ""
            let p = json["p"] as? [Any] ?? []
            
            // Handle protocol errors
            if m == "protocol_error" {
                print("❌ TradingView protocol error: \(p)")
                DispatchQueue.main.async {
                    self.tradingViewConnected = false
                    self.scheduleTradingViewReconnect()
                }
                return
            }
            
            // Handle quote data (qsd)
            if m == "qsd", p.count >= 2,
               let quoteData = p[1] as? [String: Any],
               let symbolName = quoteData["n"] as? String,  // e.g., "NASDAQ:AAPL"
               let values = quoteData["v"] as? [String: Any] {
                
                // Find our stock
                let symbol = "TV:\(symbolName)"
                
                DispatchQueue.main.async {
                    if var stock = self.tradingViewStocks[symbol] {
                        // Update price
                        if let lp = values["lp"] as? Double {
                            stock.price = lp
                        }
                        // Update change percent
                        if let chp = values["chp"] as? Double {
                            stock.changePercent24h = chp
                        }
                        // Update open price for reference
                        if let openPrice = values["open_price"] as? Double {
                            stock.open24h = openPrice
                        }
                        stock.lastUpdate = Date()
                        self.tradingViewStocks[symbol] = stock
                        self.updateStatusBar()
                    }
                }
            }
        }
    }
    
    private func scheduleTradingViewReconnect() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.scheduleTradingViewReconnect() }
            return
        }
        guard hasTradingViewSelection, !tradingViewReconnectScheduled else { return }
        tradingViewReconnectScheduled = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.tradingViewReconnectScheduled = false
            guard self.hasTradingViewSelection, !self.tradingViewConnected else { return }
            self.connectToTradingView()
        }
    }
    
    // MARK: - URLSessionWebSocketDelegate
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            if session === self.coinbaseSession {
                print("✅ Coinbase WebSocket connected!")
                self.coinbaseConnected = true
                self.coinbaseReconnectScheduled = false
                self.coinbaseLastMessage = Date()
                self.setupMenu()
                self.sendCoinbaseSubscription()
                self.receiveCoinbaseMessage()
            } else if session === self.hyperliquidSession {
                print("✅ Hyperliquid WebSocket connected!")
                self.hyperliquidConnected = true
                self.hyperliquidReconnectScheduled = false
                self.hyperliquidLastMessage = Date()
                self.setupMenu()
                self.sendHyperliquidSubscription()
                self.receiveHyperliquidMessage()
            } else if session === self.hip3Session {
                print("✅ HIP-3 WebSocket connected!")
                self.hip3Connected = true
                self.hip3ReconnectScheduled = false
                self.hip3LastMessage = Date()
                self.setupMenu()
                self.sendHIP3Subscription()
                self.receiveHIP3Message()
            } else if session === self.tradingViewSession {
                print("✅ TradingView WebSocket connected!")
                self.tradingViewConnected = true
                self.tradingViewReconnectScheduled = false
                self.tradingViewLastMessage = Date()
                self.setupMenu()
                self.sendTradingViewSubscription()
                self.receiveTradingViewMessage()
            }
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            if session === self.coinbaseSession {
                print("❌ Coinbase WebSocket closed")
                self.coinbaseConnected = false
                self.setupMenu()
                self.scheduleCoinbaseReconnect()
            } else if session === self.hyperliquidSession {
                print("❌ Hyperliquid WebSocket closed")
                self.hyperliquidConnected = false
                self.setupMenu()
                self.scheduleHyperliquidReconnect()
            } else if session === self.hip3Session {
                print("❌ HIP-3 WebSocket closed")
                self.hip3Connected = false
                self.setupMenu()
                self.scheduleHIP3Reconnect()
            } else if session === self.tradingViewSession {
                print("❌ TradingView WebSocket closed")
                self.tradingViewConnected = false
                self.setupMenu()
                self.scheduleTradingViewReconnect()
            }
        }
    }
    
    // MARK: - UI Updates
    
    private func updateStatusBar() {
        let entries: [String] = selectedCryptos.prefix(3).compactMap { symbol in
            guard let crypto = getCrypto(symbol) else { return nil }
            if crypto.price == 0 { return "\(crypto.emoji) ..." }
            let priceStr = formatPrice(crypto.price)
            let changeStr = formatPercentChange(crypto.changePercent24h)
            return "\(crypto.emoji) $\(priceStr) \(changeStr)"
        }
        
        if let button = statusItem?.button {
            button.title = entries.isEmpty ? "₿ Loading..." : entries.joined(separator: " | ")
        }
    }
    
    private func formatPrice(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        
        let fractionDigits: Int
        switch abs(price) {
        case ..<0.0001: fractionDigits = 8
        case ..<0.01: fractionDigits = 6
        case ..<1: fractionDigits = 4
        case ..<10: fractionDigits = 3
        case ..<1000: fractionDigits = 2
        default: fractionDigits = 2
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
        
        let str = formatter.string(from: NSNumber(value: change)) ?? "0.00"
        return "(\(str)%)"
    }
}
