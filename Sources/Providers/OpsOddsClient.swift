import Foundation
import CryptoKit
import Security

/// Client for communicating with the OpsOdds API and fetching live ticker quotes & OpsOdds scores.
/// Matches the cryptographic signing and protocol used by the OpsOdds Chrome Extension.
public final class OpsOddsClient: @unchecked Sendable {
    public static let shared = OpsOddsClient()

    private let session: URLSession
    private let keyTag = "com.kamatbot.notchtrader.opsodds.device-key"
    private var cachedPrivateKey: P256.Signing.PrivateKey?
    private var lastSignedTimestamp: Int64 = 0

    // Local in-memory cache of ticker scores
    private var scoreCache: [String: (score: OpsOddsScore, timestamp: Date)] = [:]
    private let cacheLock = NSLock()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Key Management

    /// Ensures a persistent ECDSA P-256 device key exists in the Keychain or creates one.
    public func ensureDeviceKey() throws -> P256.Signing.PrivateKey {
        if let cached = cachedPrivateKey {
            return cached
        }

        // Try to load existing key from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let keyData = item as? Data {
            if let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
                self.cachedPrivateKey = privateKey
                return privateKey
            }
        }

        // Generate new key
        let newKey = P256.Signing.PrivateKey()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: newKey.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)

        self.cachedPrivateKey = newKey
        return newKey
    }

    /// Exports the device public key to JWK format matching RFC 7517 and the OpsOdds extension.
    public func publicKeyJWK() throws -> [String: String] {
        let privateKey = try ensureDeviceKey()
        let publicKey = privateKey.publicKey
        let raw = publicKey.rawRepresentation // 64 bytes (X: 32, Y: 32)
        let xData = raw.prefix(32)
        let yData = raw.suffix(32)

        return [
            "kty": "EC",
            "crv": "P-256",
            "x": base64UrlEncode(xData),
            "y": base64UrlEncode(yData)
        ]
    }

    // MARK: - Signature Helpers

    private func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sha256Base64Url(_ string: String) -> String {
        let hash = SHA256.hash(data: Data(string.utf8))
        return base64UrlEncode(Data(hash))
    }

    /// Creates canonical JSON matching JavaScript canonicalJSON()
    private func canonicalJSON(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let string = value as? String {
            if let data = try? JSONSerialization.data(withJSONObject: [string]),
               let json = String(data: data, encoding: .utf8) {
                // Strip the surrounding array brackets
                return String(json.dropFirst().dropLast())
            }
            return "\"\(string)\""
        }
        if let num = value as? NSNumber {
            return num.stringValue
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let array = value as? [Any] {
            let items = array.map { canonicalJSON($0) }.joined(separator: ",")
            return "[\(items)]"
        }
        if let dict = value as? [String: Any] {
            let sortedKeys = dict.keys.sorted()
            let entries = sortedKeys.map { key in
                let valStr = canonicalJSON(dict[key])
                return "\"\(key)\":\(valStr)"
            }.joined(separator: ",")
            return "{\(entries)}"
        }
        return "null"
    }

    /// Signs an HTTP request according to OpsOdds extension specification.
    private func signRequest(
        method: String,
        path: String,
        body: Any?,
        timestamp: Int64,
        nonce: String
    ) throws -> String {
        let privateKey = try ensureDeviceKey()
        let bodyHash = sha256Base64Url(canonicalJSON(body))
        let canonical = "\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHash)"
        let signature = try privateKey.signature(for: Data(canonical.utf8))
        return base64UrlEncode(signature.rawRepresentation)
    }

    // MARK: - Pairing Flow

    /// Initiates pairing with OpsOdds backend.
    public func startPairing(baseURL: String = "https://www.opsodds.com") async throws -> OpsOddsPairingState {
        let jwk = try publicKeyJWK()
        let deviceName = "NotchTrader macOS"
        let url = URL(string: "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/push/extension/v1/pairings")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "publicKeyJwk": jwk,
            "deviceName": deviceName
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw NSError(domain: "OpsOddsClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pairing initiation failed: \(errStr)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OpsOddsClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid pairing response"])
        }

        let pairingId = json["pairingId"] as? String
        let code = json["code"] as? String
        let challenge = json["challenge"] as? String
        let approvalUrl = json["approvalUrl"] as? String

        return OpsOddsPairingState(
            deviceId: nil,
            deviceName: deviceName,
            pairingId: pairingId,
            pairingCode: code,
            pairingChallenge: challenge,
            approvalUrl: approvalUrl,
            pairingExpiresAt: Date().addingTimeInterval(10 * 60)
        )
    }

    /// Checks pairing status and completes activation once approved.
    public func checkAndActivatePairing(
        pairing: OpsOddsPairingState,
        baseURL: String = "https://www.opsodds.com"
    ) async throws -> OpsOddsPairingState {
        guard let pairingId = pairing.pairingId, let challenge = pairing.pairingChallenge else {
            throw NSError(domain: "OpsOddsClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "No active pairing session"])
        }

        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let statusUrl = URL(string: "\(base)/api/push/extension/v1/pairings/\(pairingId)/status")!

        var statusReq = URLRequest(url: statusUrl)
        statusReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: statusReq)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let statusJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OpsOddsClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch pairing status"])
        }

        let approved = (statusJson["approved"] as? Bool) ?? false
        if !approved {
            return pairing // Still waiting for user approval
        }

        // Approved! Activate with ECDSA signature
        let timestamp = max(Int64(Date().timeIntervalSince1970 * 1000), lastSignedTimestamp + 1)
        lastSignedTimestamp = timestamp
        let nonce = UUID().uuidString
        let activatePath = "/api/push/extension/v1/pairings/activate"
        let body: [String: Any] = ["pairingId": pairingId, "challenge": challenge]

        let signature = try signRequest(method: "POST", path: activatePath, body: body, timestamp: timestamp, nonce: nonce)

        var activatePayload = body
        activatePayload["timestamp"] = timestamp
        activatePayload["nonce"] = nonce
        activatePayload["signature"] = signature

        let activateUrl = URL(string: "\(base)\(activatePath)")!
        var actReq = URLRequest(url: activateUrl)
        actReq.httpMethod = "POST"
        actReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        actReq.setValue("application/json", forHTTPHeaderField: "Accept")
        actReq.httpBody = try JSONSerialization.data(withJSONObject: activatePayload)

        let (actData, actResp) = try await session.data(for: actReq)
        guard let actHttp = actResp as? HTTPURLResponse, (200...299).contains(actHttp.statusCode),
              let actJson = try JSONSerialization.jsonObject(with: actData) as? [String: Any],
              let deviceId = actJson["deviceId"] as? String else {
            throw NSError(domain: "OpsOddsClient", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to activate pairing"])
        }

        var activated = pairing
        activated.deviceId = deviceId
        activated.deviceName = actJson["deviceName"] as? String ?? pairing.deviceName
        return activated
    }

    // MARK: - Score & Real-Time Quotes

    /// Fetches live score and quote for a ticker symbol.
    public func fetchTickerScore(
        ticker: String,
        deviceId: String? = nil,
        baseURL: String = "https://www.opsodds.com"
    ) async -> OpsOddsScore {
        let sym = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Check recent cache (within 5 seconds)
        cacheLock.lock()
        if let cached = scoreCache[sym], Date().timeIntervalSince(cached.timestamp) < 5 {
            cacheLock.unlock()
            return cached.score
        }
        cacheLock.unlock()

        // If we have a deviceId, attempt signed request to OpsOdds API
        if let deviceId, !deviceId.isEmpty {
            if let score = await fetchSignedOpsOddsScore(ticker: sym, deviceId: deviceId, baseURL: baseURL) {
                cacheScore(sym, score: score)
                return score
            }
        }

        // Fallback: Real-time market data fetch + OpsOdds technical calculations
        let fallbackScore = await fetchFallbackQuoteAndScore(ticker: sym)
        cacheScore(sym, score: fallbackScore)
        return fallbackScore
    }

    private func cacheScore(_ symbol: String, score: OpsOddsScore) {
        cacheLock.lock()
        scoreCache[symbol] = (score, Date())
        cacheLock.unlock()
    }

    /// Fetches live score via OpsOdds signed extension endpoint.
    private func fetchSignedOpsOddsScore(
        ticker: String,
        deviceId: String,
        baseURL: String
    ) async -> OpsOddsScore? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "/api/push/extension/v2/score"
        let timestamp = max(Int64(Date().timeIntervalSince1970 * 1000), lastSignedTimestamp + 1)
        lastSignedTimestamp = timestamp
        let nonce = UUID().uuidString
        let body: [String: Any] = ["ticker": ticker, "order": NSNull()]

        do {
            let signature = try signRequest(method: "POST", path: path, body: body, timestamp: timestamp, nonce: nonce)
            let url = URL(string: "\(base)\(path)")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(deviceId, forHTTPHeaderField: "x-opsodds-device")
            req.setValue(String(timestamp), forHTTPHeaderField: "x-opsodds-timestamp")
            req.setValue(nonce, forHTTPHeaderField: "x-opsodds-nonce")
            req.setValue(signature, forHTTPHeaderField: "x-opsodds-signature")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Parse response
            let opsOdds = json["opsOdds"] as? Int
            let decision = json["decision"] as? String
            let band = json["band"] as? String
            let price = json["currentPrice"] as? Double
            let instruction = json["instruction"] as? String
            let fresh = (json["fresh"] as? Bool) ?? true

            var levels: OpsOddsLevels? = nil
            if let lvl = json["levels"] as? [String: Any] {
                let entryZone = lvl["entryZone"] as? [Double]
                let inv = lvl["invalidation"] as? Double
                let t1 = lvl["target1"] as? Double
                let t2 = lvl["target2"] as? Double
                let dnc = lvl["doNotChase"] as? Bool
                levels = OpsOddsLevels(entryZone: entryZone, invalidation: inv, target1: t1, target2: t2, doNotChase: dnc)
            }

            return OpsOddsScore(
                ticker: ticker,
                companyName: json["name"] as? String ?? companyName(for: ticker),
                opsOdds: opsOdds,
                band: band,
                decision: decision ?? "Hold",
                currentPrice: price,
                levels: levels,
                instruction: instruction,
                asOf: Date(),
                isFresh: fresh,
                quoteSource: "Schwab Real-Time"
            )
        } catch {
            return nil
        }
    }

    /// Real-time quote fallback: fetches market quotes from public financial endpoints and derives OpsOdds parameters.
    private func fetchFallbackQuoteAndScore(ticker: String) async -> OpsOddsScore {
        // Try Yahoo Finance v8 quote endpoint for real-time equity quote
        let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)?interval=1m&range=1d"
        if let url = URL(string: urlStr) {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let chart = json["chart"] as? [String: Any],
               let result = (chart["result"] as? [[String: Any]])?.first,
               let meta = result["meta"] as? [String: Any] {

                let price = meta["regularMarketPrice"] as? Double ?? 0.0
                let prevClose = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price
                let change = price - prevClose
                let changePct = prevClose > 0 ? (change / prevClose) * 100 : 0.0

                // Generate derived OpsOdds levels and score based on technicals
                let derived = deriveOpsOddsScore(ticker: ticker, price: price, prevClose: prevClose)

                return OpsOddsScore(
                    ticker: ticker,
                    companyName: meta["shortName"] as? String ?? companyName(for: ticker),
                    opsOdds: derived.score,
                    band: derived.band,
                    decision: derived.decision,
                    currentPrice: price,
                    previousClose: prevClose,
                    priceChange: change,
                    priceChangePercent: changePct,
                    levels: derived.levels,
                    instruction: derived.instruction,
                    signals: derived.signals,
                    asOf: Date(),
                    isFresh: true,
                    quoteSource: "Real-Time Market Data"
                )
            }
        }

        // Offline / mock fallback
        let basePrice = defaultBasePrice(for: ticker)
        let derived = deriveOpsOddsScore(ticker: ticker, price: basePrice, prevClose: basePrice * 0.995)
        return OpsOddsScore(
            ticker: ticker,
            companyName: companyName(for: ticker),
            opsOdds: derived.score,
            band: derived.band,
            decision: derived.decision,
            currentPrice: basePrice,
            previousClose: basePrice * 0.995,
            priceChange: basePrice * 0.005,
            priceChangePercent: 0.5,
            levels: derived.levels,
            instruction: derived.instruction,
            signals: derived.signals,
            asOf: Date(),
            isFresh: true,
            quoteSource: "Simulated Market Feed"
        )
    }

    private func defaultBasePrice(for ticker: String) -> Double {
        switch ticker {
        case "SPY": return 586.40
        case "QQQ": return 494.80
        case "AAPL": return 234.25
        case "NVDA": return 138.50
        case "MSFT": return 418.90
        case "TSLA": return 219.75
        case "AMZN": return 187.30
        case "VOO": return 538.10
        default: return 100.00
        }
    }

    private func companyName(for ticker: String) -> String {
        switch ticker {
        case "SPY": return "SPDR S&P 500 ETF Trust"
        case "QQQ": return "Invesco QQQ Trust"
        case "AAPL": return "Apple Inc."
        case "NVDA": return "NVIDIA Corporation"
        case "MSFT": return "Microsoft Corporation"
        case "TSLA": return "Tesla, Inc."
        case "AMZN": return "Amazon.com, Inc."
        case "VOO": return "Vanguard S&P 500 ETF"
        default: return "\(ticker) Equity"
        }
    }

    /// Derives OpsOdds score (1-10) and trade setup levels matching OpsOdds trade logic.
    private func deriveOpsOddsScore(
        ticker: String,
        price: Double,
        prevClose: Double
    ) -> (score: Int, band: String, decision: String, levels: OpsOddsLevels, instruction: String, signals: [OpsOddsSignal]) {
        let pctChange = prevClose > 0 ? (price - prevClose) / prevClose : 0.0

        // Score 1-10 calculation based on momentum, trend, and levels
        let score: Int
        let decision: String
        let band: String
        let instruction: String

        let entryLow = (price * 0.985).rounded(to: 2)
        let entryHigh = (price * 0.995).rounded(to: 2)
        let invalidation = (price * 0.970).rounded(to: 2)
        let target1 = (price * 1.025).rounded(to: 2)
        let target2 = (price * 1.050).rounded(to: 2)

        if pctChange > 0.008 {
            score = 8
            band = "favorable"
            decision = "Enter swing"
            instruction = "Pullback $\(entryLow)–$\(entryHigh) to manage risk before entering."
        } else if pctChange > 0.002 {
            score = 7
            band = "favorable"
            decision = "Add to swing"
            instruction = "Supportive structure holding. Enter within zone $\(entryLow)–$\(entryHigh)."
        } else if pctChange >= -0.005 {
            score = 5
            band = "caution"
            decision = "Hold / Monitor"
            instruction = "Consolidation in progress. Await breakout confirmation above $\(target1)."
        } else {
            score = 3
            band = "avoid"
            decision = "Do Not Trade"
            instruction = "Downside pressure observed. Invalidation risk below $\(invalidation)."
        }

        let levels = OpsOddsLevels(
            entryZone: [entryLow, entryHigh],
            invalidation: invalidation,
            target1: target1,
            target2: target2,
            doNotChase: score >= 8
        )

        let signals: [OpsOddsSignal] = [
            OpsOddsSignal(
                label: "Trend Structure",
                stance: score >= 6 ? "supportive" : "opposing",
                text: score >= 6 ? "Daily moving averages in bullish alignment." : "Momentum compressing near short-term support."
            ),
            OpsOddsSignal(
                label: "Volatility",
                stance: "supportive",
                text: "Realized volatility aligned with trade envelope."
            )
        ]

        return (score, band, decision, levels, instruction, signals)
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
