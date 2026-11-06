// 来源：APIQuota 1.11.0 WorkBuddyUsage.swift（原样复用）
import Foundation

enum WorkBuddyReadError: LocalizedError {
    case login, unsupported, encrypted, request(Int), data, tampered, runtime
    var errorDescription: String? {
        switch self {
        case .login: return "请打开 WorkBuddy 登录后刷新"
        case .encrypted: return "此版本的 WorkBuddy 登录态已加密，暂不支持读取积分"
        case .unsupported: return "当前 WorkBuddy 账户类型暂不支持"
        case .request(let status): return "WorkBuddy 查询失败（HTTP \(status)）"
        case .data: return "WorkBuddy 积分数据不完整"
        case .tampered: return "WorkBuddy 登录文件权限异常，已拒绝读取"
        case .runtime: return "未找到可用的 WorkBuddy 客户端（请确认桌面端已安装并登录）"
        }
    }
}

enum WorkBuddyReader {
    // ponytail: 复用本机个人账户登录，企业账户以后再接入独立的企业用量接口。
    static func fetch() async throws -> Snapshot {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
        // 安全加固：该文件含 WorkBuddy 登录票据，先校验属主与写权限，防被同机恶意文件替换。
        guard LocalFileGuard.trusted(path.path) else { throw WorkBuddyReadError.tampered }
        guard let bytes = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let auth = root["auth"] as? [String: Any], let account = root["account"] as? [String: Any] else { throw WorkBuddyReadError.login }
        let token: String
        switch auth["accessToken"] {
        case .some(let plain as String):
            guard plain.hasPrefix("eyJ") else { throw WorkBuddyReadError.login }
            token = plain
        case .some(let envelope as [String: Any]):
            token = try await WorkBuddyEnvelope.open(envelope)
        default:
            throw WorkBuddyReadError.login
        }
        guard let uid = account["uid"] as? String, !uid.isEmpty else { throw WorkBuddyReadError.login }
        guard (account["enterpriseId"] as? String ?? "").isEmpty,
              let domain = auth["domain"] as? String,
              ["www.codebuddy.cn", "www.workbuddy.cn", "copilot.tencent.com"].contains(domain) else { throw WorkBuddyReadError.unsupported }
        if let expiry = auth["expiresAt"] as? Double, expiry <= Date().timeIntervalSince1970 * 1000 { throw WorkBuddyReadError.login }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        config.urlCache = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // 固定官方地址并禁止跳转，登录票据不写入组件缓存或日志。
        var request = URLRequest(url: URL(string: Provider.workbuddy.endpoint)!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("NotchHub", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(uid, forHTTPHeaderField: "X-User-Id")
        request.setValue(domain, forHTTPHeaderField: "X-Domain")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WorkBuddyReadError.data }
        if response.statusCode == 401 { throw WorkBuddyReadError.login }
        guard response.statusCode == 200 else { throw WorkBuddyReadError.request(response.statusCode) }
        return Snapshot(money: [Money(currency: "CREDITS", value: try balance(data))], updated: Date())
    }
    static func balance(_ data: Data) throws -> Decimal {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(), code.intValue == 0,
              let result = root["data"] as? [String: Any], let packages = result["Packages"] as? [[String: Any]] else { throw WorkBuddyReadError.data }
        var total: Decimal = 0
        for item in packages {
            guard item["CapacityUnit"] as? String == "credits" else { throw WorkBuddyReadError.data }
            let amount = try QuotaAPI.decimal(item["CycleRemainCapacity"])
            total += max(0, amount)
        }
        return total
    }
}


func workBuddySelfTest() throws {
    let data = Data(#"{"code":0,"data":{"Packages":[{"CapacityUnit":"credits","CycleRemainCapacity":"1144.01000064"},{"CapacityUnit":"credits","CycleRemainCapacity":"500"}]}}"#.utf8)
    let total = try WorkBuddyReader.balance(data)
    precondition(total == Decimal(string: "1644.01000064")!)
    for invalid in [#"{"code":0,"data":{}}"#, #"{"code":0,"data":{"Packages":[{"CapacityUnit":"credits","CycleRemainCapacity":true}]}}"#, #"{"code":false,"data":{"Packages":[]}}"#] {
        do { _ = try WorkBuddyReader.balance(Data(invalid.utf8)); preconditionFailure("不能把无效数据视为零余额") } catch {}
    }
    let zero = try WorkBuddyReader.balance(Data(#"{"code":0,"data":{"Packages":[]}}"#.utf8))
    precondition(zero == 0)
    try WorkBuddyEnvelope.selfTest()
    print("通过：WorkBuddy 多积分包精度、零余额、无效数据校验。")
}
