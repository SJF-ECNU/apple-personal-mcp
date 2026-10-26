import AppKit
import Foundation
import Security

public enum AppIdentity {
    public static let host = "com.shjf.apple-personal-mcp"
    public static let bridge = "com.shjf.apple-personal-mcp.bridge"
    public static let service = "com.shjf.apple-personal-mcp.service"
    public static let ownerService = "com.shjf.apple-personal-mcp.owner"
    public static let version = "0.5.0"
    public static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ApplePersonalMCP") }
    public static func peerRequirement(identifier: String) throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw ServiceError("signing_required", "Cannot obtain own code signature") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw ServiceError("signing_required", "Cannot inspect own signing identity") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw ServiceError("signing_required", "Build and sign the app before using XPC")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc public protocol HostProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
    func cancel(_ requestID: String)
}

@objc public protocol OwnerProtocol {
    func requestEventKitPermissions(_ reply: @escaping (Data) -> Void)
    func inspectLocalSources(_ reply: @escaping (Data) -> Void)
    func requestNotesPermission(_ reply: @escaping (Data) -> Void)
    func requestMessagesPermission(_ reply: @escaping (Data) -> Void)
    func showAgentManagement(_ reply: @escaping (Data) -> Void)
}

/// Separate signed-app-only endpoint; never exposed to MCP bridges.
public final class OwnerClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    public init() throws {
        connection = NSXPCConnection(machServiceName: AppIdentity.ownerService)
        connection.remoteObjectInterface = NSXPCInterface(with: OwnerProtocol.self)
        connection.setCodeSigningRequirement(try AppIdentity.peerRequirement(identifier: AppIdentity.host))
        connection.resume()
    }
    deinit { connection.invalidate() }
    public func requestEventKitPermissions() async throws -> Data { try await send { $0.requestEventKitPermissions($1) } }
    public func inspectLocalSources() async throws -> Data { try await send { $0.inspectLocalSources($1) } }
    public func requestNotesPermission() async throws -> Data { try await send { $0.requestNotesPermission($1) } }
    public func showAgentManagement() async throws -> Data { try await send { $0.showAgentManagement($1) } }
    public func requestMessagesPermission() async throws -> Data { try await send { $0.requestMessagesPermission($1) } }

    private func send(_ invoke: (OwnerProtocol, @escaping (Data) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = ReplyOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.finish(.failure($0)) }
            guard let owner = proxy as? OwnerProtocol else { once.finish(.failure(ServiceError("host_unavailable", "Enable the App user service"))); return }
            invoke(owner) { once.finish(.success($0)) }
        }
    }
}

public struct HostRequest: Codable, Sendable {
    public let method: String
    public let tool: String?
    public let arguments: [String: JSON]
    public let readOnly: Bool
    public let credential: AgentCredential?
    public let requestID: String?
    public init(method: String, tool: String? = nil, arguments: [String: JSON] = [:], readOnly: Bool, credential: AgentCredential? = nil, requestID: String = UUID().uuidString) {
        self.method = method; self.tool = tool; self.arguments = arguments; self.readOnly = readOnly
        self.credential = credential
        self.requestID = requestID
    }
}

public final class HostClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    public init() throws {
        connection = NSXPCConnection(machServiceName: AppIdentity.service)
        connection.remoteObjectInterface = NSXPCInterface(with: HostProtocol.self)
        connection.setCodeSigningRequirement(try AppIdentity.peerRequirement(identifier: AppIdentity.host))
        connection.resume()
    }
    deinit { connection.invalidate() }
    public func send(_ request: HostRequest) async throws -> Data {
        let data = try JSONEncoder().encode(request)
        let reply: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let once = ReplyOnce(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in once.finish(.failure(error)) }
                guard let host = proxy as? HostProtocol else { once.finish(.failure(ServiceError("host_unavailable", "Open ApplePersonalMCP.app and enable its user service"))); return }
                host.request(data) { once.finish(.success($0)) }
            }
        } onCancel: {
            if let id = request.requestID { (self.connection.remoteObjectProxyWithErrorHandler { _ in } as? HostProtocol)?.cancel(id) }
        }
        try Task.checkCancellation(); return reply
    }
}

private final class ReplyOnce {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}
