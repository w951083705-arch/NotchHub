// 来源：AgentHUD 交互恢复版 Approval.swift（审批通道，去掉旧卡片视图）
import Foundation
import SwiftUI
import AppKit
import Darwin

// ============================================================
// 审批通道：Unix socket 服务 + 可点击审批卡
// 协议：客户端连上后发一行 JSON
//   {"id":"...","tool":"bash","command":"...","reason":"...","agent":"DSH"}
// HUD 回一行 JSON
//   {"id":"...","decision":"allowed-once"|"rejected"|"unavailable"}
// ============================================================

let SOCKET_PATH = ProcessInfo.processInfo.environment["AGENTHUD_APPROVAL_SOCKET"] ?? "/tmp/agenthud-approval.sock"
let APPROVAL_TIMEOUT: TimeInterval = 110

struct ApprovalReq: Identifiable, Equatable {
    let id: String
    let tool: String
    let command: String
    let reason: String
    let agent: String
    let received: Date
    let expires: Date
}

final class ApprovalCenter: ObservableObject {
    @Published var pending: ApprovalReq?
    @Published var history: [String] = []

    /// 每个请求自己的回调（按 id 索引），支持并发排队
    private var completions: [String: (String) -> Void] = [:]
    private var waiting: [ApprovalReq] = []
    private var expirations: [String: DispatchWorkItem] = [:]

    func ask(_ req: ApprovalReq, completion: @escaping (String) -> Void) {
        guard req.expires > Date(), completions[req.id] == nil else { completion("unavailable"); return }
        completions[req.id] = completion
        let expiry = DispatchWorkItem { [weak self] in self?.cancel(req.id) }
        expirations[req.id] = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + req.expires.timeIntervalSinceNow, execute: expiry)
        if pending == nil { pending = req } else { waiting.append(req) }
    }

    func cancel(_ id: String) { finish(id, decision: "unavailable") }

    private func finish(_ id: String, decision: String) {
        guard let completion = completions.removeValue(forKey: id) else { return }
        expirations.removeValue(forKey: id)?.cancel()
        waiting.removeAll { $0.id == id }
        if pending?.id == id {
            pending = nil
            history.append(decision)
            if history.count > 30 { history.removeFirst() }
            if !waiting.isEmpty { pending = waiting.removeFirst() }
        }
        completion(decision)
    }

    func decide(_ decision: String) {
        guard let request = pending else { return }
        let result = request.expires > Date() && ["allowed-once", "rejected"].contains(decision) ? decision : "unavailable"
        finish(request.id, decision: result)
    }

    var isWaiting: Bool { pending != nil }
}

// ============================================================
// Unix socket 服务
// ============================================================

final class ApprovalServer {
    private let center: ApprovalCenter
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "agenthud.approval.accept", qos: .userInitiated)

    init(center: ApprovalCenter) { self.center = center }

    func start() -> Bool {
        guard SOCKET_PATH.utf8.count < 104 else { return false }
        // 避免第二个实例抢走正在服务的 socket。
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        var existing = sockaddr_un()
        existing.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &existing.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strcpy($0, SOCKET_PATH) }
        }
        let active = withUnsafePointer(to: &existing) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        close(probe)
        if active { NSLog("approval: 已有实例运行"); return false }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: SOCKET_PATH) {
            guard attributes[.type] as? FileAttributeType == .typeSocket,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        }
        unlink(SOCKET_PATH)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { NSLog("approval: socket failed"); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = strcpy(dst, SOCKET_PATH)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            NSLog("approval: bind/listen failed \(errno)")
            close(listenFD)
            return false
        }
        guard chmod(SOCKET_PATH, 0o600) == 0 else { close(listenFD); return false }
        NSLog("approval: listening \(SOCKET_PATH)")

        queue.async { [weak self] in
            while true {
                let client = accept(self?.listenFD ?? -1, nil, nil)
                if client < 0 { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.handle(client)
                }
            }
        }
        return true
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // 5 秒内没收到完整请求就断开，防止半开连接永久挂住线程
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 8192)
        var acc = Data()
        // 读一行
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            acc.append(contentsOf: buf[0..<n])
            if acc.count > 64 * 1024 { return }
            if acc.contains(0x0A) { break }
        }
        guard let line = String(data: acc, encoding: .utf8)?
            .split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return }

        let replyID = (obj["id"] as? String) ?? UUID().uuidString
        let requestedTimeout = (obj["timeoutMs"] as? Double) ?? 120_000
        guard requestedTimeout.isFinite, requestedTimeout > 0 else { return }
        let expires = Date().addingTimeInterval(min(APPROVAL_TIMEOUT, max(0.1, requestedTimeout / 1000 - 2)))
        let req = ApprovalReq(
            id: UUID().uuidString,
            tool: (obj["tool"] as? String) ?? "tool",
            command: (obj["command"] as? String) ?? (obj["reason"] as? String) ?? "",
            reason: (obj["reason"] as? String) ?? "",
            agent: (obj["agent"] as? String) ?? "DSH",
            received: Date(), expires: expires
        )

        let sem = DispatchSemaphore(value: 0)
        var decision = "unavailable"
        DispatchQueue.main.async {
            self.center.ask(req) { d in
                decision = d
                sem.signal()
            }
        }
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                DispatchQueue.main.sync { self.center.cancel(req.id) }
                return
            }
            if Date() >= req.expires {
                DispatchQueue.main.sync { self.center.cancel(req.id) }
                break
            }
        }
        let reply: [String: Any] = ["id": replyID, "decision": decision]
        if let data = try? JSONSerialization.data(withJSONObject: reply) {
            var out = data
            out.append(0x0A)
            out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if let base = raw.baseAddress {
                    var offset = 0
                    while offset < raw.count {
                        let count = write(fd, base.advanced(by: offset), raw.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        if count <= 0 { break }
                        offset += count
                    }
                }
            }
        }
    }
}

// ============================================================
// 审批卡
// ============================================================
