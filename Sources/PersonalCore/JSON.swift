import Foundation

public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else { self = .array(try c.decode([JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max), v.rounded() == v { return Int(v) }; return nil }
    public var boolean: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [JSON]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: JSON]? { if case .object(let v) = self { return v }; return nil }
    public static func int(_ n: Int) -> JSON { .number(Double(n)) }
    public static func encoded<T: Encodable>(_ v: T) throws -> JSON { try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(v)) }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public func text() -> String { String(data: (try? data()) ?? Data(), encoding: .utf8) ?? "{}" }
}

public struct ServiceError: Error, CustomStringConvertible {
    public let code: String
    public let description: String
    public init(_ code: String, _ description: String) { self.code = code; self.description = description }
}

public struct Arguments {
    public let values: [String: JSON]
    public init(_ values: [String: JSON]) { self.values = values }
    public func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = values[key] else {
            if required { throw ServiceError("invalid_arguments", "Missing \(key)") }; return nil
        }
        guard let s = value.string, !required || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError("invalid_arguments", "\(key) must be a string")
        }
        return s
    }
    public func requiredString(_ key: String) throws -> String { try string(key, required: true)! }
    public func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let v = values[key] else { return fallback }
        guard let n = v.int, range.contains(n) else { throw ServiceError("invalid_arguments", "\(key) must be in \(range)") }
        return n
    }
    public func bool(_ key: String) throws -> Bool? {
        guard let v = values[key] else { return nil }
        guard let b = v.boolean else { throw ServiceError("invalid_arguments", "\(key) must be boolean") }; return b
    }
    public func id(_ key: String = "id") throws -> Int64 {
        guard let s = values[key]?.string, let n = Int64(s), n > 0 else { throw ServiceError("invalid_arguments", "\(key) must be a positive decimal ID string") }; return n
    }
}

public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSON
    public let readOnly: Bool
    public init(_ name: String, _ description: String, _ properties: [String: JSON] = [:], required: [String] = [], readOnly: Bool = true) {
        self.name = name; self.description = description; self.readOnly = readOnly
        inputSchema = .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)])
    }
    public static func field(_ type: String, _ description: String) -> JSON { .object(["type": .string(type), "description": .string(description)]) }
}

public struct ToolReply: Codable, Sendable {
    public let isError: Bool
    public let body: JSON
    public init(_ body: JSON, isError: Bool = false) { self.body = body; self.isError = isError }
    public static func failure(_ error: Error) -> ToolReply {
        let e = error as? ServiceError ?? ServiceError("execution_failed", String(describing: error))
        return ToolReply(.object(["error": .object(["code": .string(e.code), "message": .string(e.description)])]), isError: true)
    }
}

public enum BodyPaging {
    public static func page(_ text: String, arguments: Arguments) throws -> JSON {
        try page(text, offset: arguments.integer("body_offset", default: 0, range: 0...Int.max), limit: arguments.integer("max_chars", default: 16000, range: 1...16000))
    }
    public static func page(_ text: String, offset: Int, limit: Int) throws -> JSON {
        let scalars = text.unicodeScalars
        guard offset >= 0, offset <= scalars.count else { throw ServiceError("invalid_cursor", "Text offset is outside the body") }
        let start = scalars.index(scalars.startIndex, offsetBy: offset)
        let end = scalars.index(start, offsetBy: min(limit, scalars.count - offset))
        let next = offset + scalars.distance(from: start, to: end)
        return .object(["text": .string(String(scalars[start..<end])), "offset": .int(offset), "total_scalars": .int(scalars.count), "next_offset": next < scalars.count ? .int(next) : .null, "content_status": .string(next < scalars.count ? "partial" : "complete")])
    }
}
