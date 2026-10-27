import Foundation

/// Wire-only values. This module deliberately has no database or app dependency.
public enum AgentJSON: Codable, Sendable, Equatable {
    case object([String: AgentJSON]), array([AgentJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        func decodeType<T: Decodable>(_ type: T.Type) throws -> T? {
            do { return try value.decode(type) }
            catch DecodingError.typeMismatch { return nil } // JSON union discrimination only.
            catch { throw error }
        }
        if value.decodeNil() { self = .null }
        else if let bool = try decodeType(Bool.self) { self = .bool(bool) }
        else if let number = try decodeType(Double.self) { self = .number(number) }
        else if let string = try decodeType(String.self) { self = .string(string) }
        else if let array = try decodeType([AgentJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: AgentJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public subscript(_ key: String) -> AgentJSON? { objectValue?[key] }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var objectValue: [String: AgentJSON]? { if case .object(let v) = self { v } else { nil } }
    public var arrayValue: [AgentJSON]? { if case .array(let v) = self { v } else { nil } }
    public static func encoding<T: Encodable>(_ value: T) throws -> AgentJSON {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(AgentJSON.self, from: encoder.encode(value))
    }
}

public struct AgentFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Only the app-side implementation may own library services. Helpers receive DTOs.
public protocol AgentBridge: Sendable {
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON
}
