// 来源：APIQuota 1.11.0 Core.swift（原样复用）
import Foundation
import Security

enum Provider: String, Codable, CaseIterable, Identifiable {
    case deepseek, kimi, glm, openai, workbuddy, claude
    var id: String { rawValue }
    var name: String { switch self { case .deepseek: "DeepSeek"; case .kimi: "Kimi"; case .glm: "GLM"; case .openai: "OpenAI"; case .workbuddy: "WorkBuddy"; case .claude: "Claude" } }
    var endpoint: String { switch self {
        case .deepseek: "https://api.deepseek.com/user/balance"
        case .kimi: "https://api.moonshot.cn/v1/users/me/balance"
        case .glm: "https://open.bigmodel.cn/api/biz/account/query-customer-account-report"
        case .openai: "https://api.openai.com/v1/organization/costs"
        case .workbuddy: "https://copilot.tencent.com/billing/meter/get-user-resource-summary"
        case .claude: ""                 // 无网络接口，读本机文件（ClaudeUsage.swift）
    } }
    /// 订阅额度类（显示剩余百分比而非余额）
    var isSubscription: Bool { self == .openai || self == .claude }
    var dashboard: String { switch self {
        case .deepseek: "https://platform.deepseek.com"
        case .kimi: "https://platform.kimi.com"
        case .glm: "https://bigmodel.cn"
        case .openai: "https://platform.openai.com/settings/organization/usage"
        case .workbuddy: "https://www.workbuddy.cn"
        case .claude: "https://claude.ai/settings/usage"
    } }
}

struct Money: Codable, Equatable {
    let currency: String
    let value: Decimal
    var text: String {
        let formatter = NumberFormatter()
        if currency == "CREDITS" {
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
            return formatter.string(from: value as NSDecimalNumber) ?? "—"
        }
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.currencySymbol = currency == "USD" ? "$" : currency == "CNY" ? "¥" : currency + " "
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "—"
    }
}

struct Snapshot: Codable {
    let money: [Money]
    let updated: Date
    var month: String? = nil
}

enum QuotaError: LocalizedError {
    case invalidData, http(Int), keychain(OSStatus), missingKey, pagination
    var errorDescription: String? {
        switch self {
        case .invalidData: "平台返回的数据格式不符"
        case .http(401): "密钥无效或平台不匹配"
        case .http(403): "无查询权限；OpenAI 需要组织费用读取权限"
        case .http(429): "平台限流，请稍后手动刷新"
        case .http(let code): "查询失败（HTTP \(code)）"
        case .keychain(let code): "钥匙串访问失败（\(code)）"
        case .missingKey: "待配置"
        case .pagination: "费用分页未完整返回"
        }
    }
}

enum Vault {
    static var service = "NotchHub.credentials"
    private static func base(_ provider: Provider, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
    }
    /// 只查是否存在，不读取密钥内容，因此不会弹钥匙串授权框。
    static func configured(_ provider: Provider) -> Bool {
        var query = base(provider, service)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
    static func delete(_ provider: Provider) throws {
        let status = SecItemDelete(base(provider, service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuotaError.keychain(status) }
    }
    static func read(_ provider: Provider) throws -> String? {
        if let value = try read(provider, service: service) { return value }
        guard let legacy = LocalCompat.legacyKeychainService else { return nil }
        return try read(provider, service: legacy)
    }
    private static func read(_ provider: Provider, service: String) throws -> String? {
        var query = base(provider, service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw QuotaError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw QuotaError.invalidData }
        return value
    }
    static func save(_ key: String, for provider: Provider) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw QuotaError.invalidData }
        let query = base(provider, service)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "NotchHub · \(provider.name)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var result = SecItemAdd(item as CFDictionary, nil)
        if result == errSecDuplicateItem {
            result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
        guard result == errSecSuccess else { throw QuotaError.keychain(result) }
    }
}

// 固定请求目标并拒绝跳转，防止凭据随重定向流向其他站点。
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum QuotaAPI {
    static func decimal(_ value: Any?) throws -> Decimal {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw QuotaError.invalidData }
            return number.decimalValue
        }
        if let string = value as? String, let result = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN { return result }
        throw QuotaError.invalidData
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["error"] == nil else { throw QuotaError.invalidData }
        return result
    }
    static func parseBalance(_ data: Data, provider: Provider) throws -> [Money] {
        let json = try object(data)
        if provider == .deepseek {
            guard let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else { throw QuotaError.invalidData }
            return try infos.map { item in
                guard let currency = item["currency"] as? String, ["CNY", "USD"].contains(currency) else { throw QuotaError.invalidData }
                return Money(currency: currency, value: try decimal(item["total_balance"]))
            }
        }
        if provider == .glm {
            // 智谱开放平台账户报告：data.availableBalance（元）。
            guard json["success"] as? Bool == true, let result = json["data"] as? [String: Any] else { throw QuotaError.invalidData }
            return [Money(currency: "CNY", value: try decimal(result["availableBalance"]))]
        }
        guard provider == .kimi, json["status"] as? Bool == true,
              let result = json["data"] as? [String: Any] else { throw QuotaError.invalidData }
        return [Money(currency: "CNY", value: try decimal(result["available_balance"]))]
    }
    static func parseCosts(_ data: Data) throws -> (Decimal, String?) {
        let json = try object(data)
        guard let buckets = json["data"] as? [[String: Any]], let more = json["has_more"] as? Bool else { throw QuotaError.invalidData }
        var sum: Decimal = 0
        for bucket in buckets {
            guard let rows = bucket["results"] as? [[String: Any]] else { throw QuotaError.invalidData }
            for row in rows {
                guard let amount = row["amount"] as? [String: Any],
                      (amount["currency"] as? String)?.lowercased() == "usd" else { throw QuotaError.invalidData }
                sum += try decimal(amount["value"])
            }
        }
        if more {
            guard let page = json["next_page"] as? String, !page.isEmpty else { throw QuotaError.pagination }
            return (sum, page)
        }
        return (sum, nil)
    }
    static func monthRange(_ now: Date) -> (Date, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .month, for: now)!.start
        let parts = calendar.dateComponents([.year, .month], from: now)
        return (start, String(format: "%04d-%02d", parts.year!, parts.month!))
    }
    static func fetch(_ provider: Provider, key: String) async throws -> Snapshot {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw QuotaError.invalidData }
            guard response.statusCode == 200 else { throw QuotaError.http(response.statusCode) }
            return data
        }
        if provider != .openai {
            return Snapshot(money: try parseBalance(await request(URL(string: provider.endpoint)!), provider: provider), updated: Date())
        }
        let now = Date()
        let (start, month) = monthRange(now)
        var total: Decimal = 0
        var page: String? = nil
        var seen = Set<String>()
        for _ in 0..<100 {
            var url = URLComponents(string: provider.endpoint)!
            url.queryItems = [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(now.timeIntervalSince1970))),
                URLQueryItem(name: "limit", value: "31")]
            if let page { url.queryItems!.append(URLQueryItem(name: "page", value: page)) }
            let (amount, next) = try parseCosts(await request(url.url!))
            total += amount
            guard let next else { return Snapshot(money: [Money(currency: "USD", value: total)], updated: now, month: month) }
            guard seen.insert(next).inserted else { throw QuotaError.pagination }
            page = next
        }
        throw QuotaError.pagination
    }
    static func errorText(_ error: Error) -> String {
        if let error = error as? QuotaError { return error.localizedDescription }
        if let error = error as? URLError {
            if error.code == .timedOut { return "连接超时，保留上次数据" }
            return "网络不可达，请检查连接（\(error.code.rawValue)）"
        }
        return "查询失败，请手动刷新"
    }
}

func selfTest() throws {
    let deep = Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"10.25"},{"currency":"USD","total_balance":"2.00"}]}"#.utf8)
    let parsed = try QuotaAPI.parseBalance(deep, provider: .deepseek)
    precondition(parsed.count == 2 && parsed[0].value == Decimal(string: "10.25"))
    let kimi = Data(#"{"status":true,"data":{"available_balance":0,"cash_balance":-2,"voucher_balance":0}}"#.utf8)
    let kimiParsed = try QuotaAPI.parseBalance(kimi, provider: .kimi)
    precondition(kimiParsed.first!.value == 0)
    for bad in [#"{"status":true,"data":{}}"#, #"{"status":false,"data":{"available_balance":20}}"#, #"{"status":true,"data":{"available_balance":true}}"#] {
        do { _ = try QuotaAPI.parseBalance(Data(bad.utf8), provider: .kimi); preconditionFailure("应拒绝无效数据") }
        catch { }
    }
    let costs = Data(#"{"data":[{"results":[{"amount":{"currency":"usd","value":0.1}},{"amount":{"currency":"usd","value":0.2}}]}],"has_more":true,"next_page":"next"}"#.utf8)
    let (sum, next) = try QuotaAPI.parseCosts(costs)
    precondition(sum == Decimal(string: "0.3") && next == "next")
    let empty = try QuotaAPI.parseCosts(Data(#"{"data":[],"has_more":false}"#.utf8))
    precondition(empty.0 == 0 && empty.1 == nil)
    let date = ISO8601DateFormatter().date(from: "2026-09-01T00:01:00Z")!
    precondition(QuotaAPI.monthRange(date).1 == "2026-09")
    print("通过：多币种、零余额、缺失字段、布尔值拒绝、费用精度、分页与月份边界。")
}

// MARK: - 本机文件守卫（安全加固 v1.6.1）
// 组件会以本机登录态调用 codex CLI、读取 WorkBuddy 登录文件、运行凭据助手。
// 这三处若被替换为恶意文件，等于把登录态交给任意代码。执行前统一校验：
//   1) 真实文件（解析符号链接后）属主必须是当前用户或 root；
//   2) 不得带组写/其他写权限（防同机其他用户植入）。
enum LocalFileGuard {
    static func trusted(_ path: String) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var st = stat()
        guard lstat(resolved, &st) == 0 else { return false }
        let uid = geteuid()
        guard st.st_uid == uid || st.st_uid == 0 else { return false }
        guard (st.st_mode & 0o022) == 0 else { return false }
        return true
    }
}

func localGuardSelfTest() throws {
    let selfExe = CommandLine.arguments.first ?? "/bin/ls"
    precondition(LocalFileGuard.trusted(selfExe), "自身可执行文件应通过守卫")
    precondition(!LocalFileGuard.trusted("/dev/null"), "其他用户可写的设备应拒绝")
    precondition(!LocalFileGuard.trusted("/nonexistent-xyz"), "不存在的路径应拒绝")
    precondition(!LocalFileGuard.trusted("/"), "目录应拒绝")
    print("通过：本机文件守卫（属主/写权限/符号链接解析）。")
}
