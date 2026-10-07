import Foundation

/// Cross-zone ordering marker. Enabling precedes the Library save; releasing
/// protection follows its server acknowledgement. Both versions only advance.
struct ICloudRetentionUnreadPolicy: Sendable, Equatable {
    static let recordName = "retention-policy-v1:articles"
    static let maximumBytes = 2_048
    let generation: String
    var protectedVersion: ICloudFieldVersion?
    var releasedVersion: ICloudFieldVersion?

    init(generation: String, protectedVersion: ICloudFieldVersion? = nil,
         releasedVersion: ICloudFieldVersion? = nil) throws {
        self.generation = generation
        self.protectedVersion = protectedVersion; self.releasedVersion = releasedVersion
        try ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3).validate()
        _ = try envelope()
    }

    init(envelope: ICloudRecordEnvelope, generation: String) throws {
        try envelope.validate()
        guard envelope.kind == .retentionPolicy else { throw ICloudRetentionError.malformedSnapshot }
        self.generation = generation
        protectedVersion = envelope.fields["protect_unread"].flatMap { $0.value == .flag(true) ? $0.version : nil }
        releasedVersion = envelope.fields["release_unread"].flatMap { $0.value == .flag(true) ? $0.version : nil }
        try ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3).validate()
    }

    /// Unknown policy and equal-version enable/disable both preserve content.
    var allowsUnreadRemoval: Bool {
        guard let releasedVersion else { return false }
        return protectedVersion.map { $0 < releasedVersion } ?? true
    }

    func protects(_ version: ICloudFieldVersion) -> Bool {
        guard let protectedVersion else { return false }
        return version <= protectedVersion && !allowsUnreadRemoval
    }

    func envelope() throws -> ICloudRecordEnvelope {
        try .init(kind: .retentionPolicy, recordName: Self.recordName, fields: [
            "protect_unread": .init(value: .flag(protectedVersion != nil), version: protectedVersion ?? .bootstrap),
            "release_unread": .init(value: .flag(releasedVersion != nil), version: releasedVersion ?? .bootstrap),
            "writer_nonce": .init(value: .text(""), version: .bootstrap)
        ])
    }

    static func validateWireData(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "kind", "recordName", "fields"],
              let fields = root["fields"] as? [String: Any],
              Set(fields.keys) == ["protect_unread", "release_unread", "writer_nonce"] else {
            throw ICloudRetentionError.malformedSnapshot
        }
        for (key, value) in fields {
            let payloadKind = key == "writer_nonce" ? "text" : "flag"
            guard let field = value as? [String: Any], Set(field.keys) == ["value", "version"],
                  let version = field["version"] as? [String: Any], Set(version.keys) == ["counter", "deviceID"],
                  let wrapped = field["value"] as? [String: Any], Set(wrapped.keys) == [payloadKind],
                  let payload = wrapped[payloadKind] as? [String: Any], Set(payload.keys) == ["_0"] else {
                throw ICloudRetentionError.malformedSnapshot
            }
        }
    }
}
