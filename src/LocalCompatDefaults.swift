import Foundation

// 公开版的默认实现。src/private/ 存在时（定义了 NOTCHHUB_LOCAL）由本机代码替换。
#if !NOTCHHUB_LOCAL
enum LocalCompat {
    static let apiQuotaBundleID: String? = nil
    static let legacyKeychainService: String? = nil
}

enum WorkBuddyEnvelope {
    static func open(_ envelope: [String: Any]) async throws -> String { throw WorkBuddyReadError.encrypted }
    static func selfTest() throws {}
}
#endif
