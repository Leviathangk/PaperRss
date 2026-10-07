import Foundation

/// Shared rolling-seven-day reservations. An accepted but not yet timestamped
/// reservation never expires. The next verified server snapshot dates it no
/// earlier than its actual commit, so a lost receipt cannot release quota early.
struct ICloudRetentionQuota: Codable, Sendable, Equatable {
    struct Reservation: Codable, Sendable, Equatable {
        let operationID: String
        let processedRecords: Int
        var confirmedAt: Date?
    }

    static let recordName = "retention-quota-v1:articles"
    static let maximumBytes = 64 * 1_024
    let schemaVersion: Int
    var clockStamp: String
    var lastServerDate: Date?
    private(set) var reservations: [Reservation]

    init(clockStamp: String = UUID().uuidString) {
        schemaVersion = 1; self.clockStamp = clockStamp; reservations = []
    }

    func validate(serverDate: Date? = nil) throws {
        guard schemaVersion == 1, Self.canonicalUUID(clockStamp),
              reservations.count <= ICloudRetentionWeek.recordLimit,
              Set(reservations.map(\.operationID)).count == reservations.count,
              reservations.allSatisfy({ Self.canonicalUUID($0.operationID) && $0.processedRecords > 0 &&
                  $0.processedRecords <= ICloudRetentionWeek.recordLimit && Self.validDate($0.confirmedAt) }),
              Self.validDate(lastServerDate) else { throw ICloudRetentionError.malformedSnapshot }
        var total = 0
        for entry in reservations {
            guard entry.processedRecords <= ICloudRetentionWeek.recordLimit - total else {
                throw ICloudRetentionError.budgetExceeded
            }
            total += entry.processedRecords
            if let date = entry.confirmedAt {
                guard let lastServerDate, date <= lastServerDate else { throw ICloudRetentionError.malformedSnapshot }
            }
        }
        if let serverDate {
            guard Self.validDate(serverDate), lastServerDate.map({ $0 <= serverDate }) ?? true,
                  reservations.allSatisfy({ $0.confirmedAt.map { $0 <= serverDate } ?? true }) else {
                throw ICloudRetentionError.malformedSnapshot
            }
        }
    }

    /// serverDate comes from the matching server CKRecord's modificationDate,
    /// never Date(), an inventory-query cursor or the user's device clock.
    func allocating(_ processedRecords: Int, operationID: String, serverDate: Date) throws -> Self {
        try validate(serverDate: serverDate)
        guard Self.canonicalUUID(operationID), processedRecords > 0,
              processedRecords <= ICloudRetentionWeek.recordLimit else { throw ICloudRetentionError.malformedSnapshot }
        if let old = reservations.first(where: { $0.operationID == operationID }) {
            guard old.processedRecords == processedRecords else { throw ICloudRetentionError.malformedSnapshot }
            return self // Ambiguous-success retry does not reserve twice.
        }
        var result = self
        result.lastServerDate = serverDate
        for index in result.reservations.indices where result.reservations[index].confirmedAt == nil {
            result.reservations[index].confirmedAt = serverDate
        }
        let cutoff = serverDate.addingTimeInterval(-ICloudRetentionWeek.duration)
        result.reservations.removeAll { $0.confirmedAt.map { $0 <= cutoff } ?? false }
        let used = result.reservations.reduce(0) { $0 + $1.processedRecords }
        guard processedRecords <= ICloudRetentionWeek.recordLimit - used else { throw ICloudRetentionError.budgetExceeded }
        result.reservations.append(.init(operationID: operationID, processedRecords: processedRecords))
        try result.validate(serverDate: serverDate)
        return result
    }

    /// A CAS clock stamp changes no article, floor or reservation. Its returned
    /// server date can refresh age/quota evidence after a long inactive period.
    func clockProbe(stamp: String) throws -> Self {
        try validate()
        guard Self.canonicalUUID(stamp), stamp != clockStamp else { throw ICloudRetentionError.malformedSnapshot }
        var result = self; result.clockStamp = stamp
        return result
    }

    /// A CAS retry must derive from the newly fetched ledger. A caller cannot
    /// replace it with a valid-looking empty value and discard another Mac's
    /// reservations. Only dated, expired entries may disappear.
    func validateTransition(to next: Self, serverDate: Date) throws {
        try validate(serverDate: serverDate); try next.validate(serverDate: serverDate)
        guard next != self,
              lastServerDate.map({ previous in next.lastServerDate.map { previous <= $0 } ?? false }) ?? true else {
            throw ICloudRetentionError.malformedSnapshot
        }
        let cutoff = serverDate.addingTimeInterval(-ICloudRetentionWeek.duration)
        let following = Dictionary(uniqueKeysWithValues: next.reservations.map { ($0.operationID, $0) })
        for previous in reservations {
            guard let current = following[previous.operationID] else {
                guard let date = previous.confirmedAt, date <= cutoff else { throw ICloudRetentionError.malformedSnapshot }
                continue
            }
            guard previous.processedRecords == current.processedRecords else { throw ICloudRetentionError.malformedSnapshot }
            if let date = previous.confirmedAt {
                guard current.confirmedAt == date else { throw ICloudRetentionError.malformedSnapshot }
            } else {
                guard current.confirmedAt == nil || current.confirmedAt == serverDate else { throw ICloudRetentionError.malformedSnapshot }
            }
        }
        let existing = Set(reservations.map(\.operationID))
        let added = next.reservations.filter { !existing.contains($0.operationID) }
        guard added.count <= 1,
              added.allSatisfy({ $0.confirmedAt == nil }),
              added.isEmpty || next.lastServerDate == serverDate else { throw ICloudRetentionError.malformedSnapshot }
    }

    func contains(operationID: String, processedRecords: Int) -> Bool {
        reservations.contains { $0.operationID == operationID && $0.processedRecords == processedRecords }
    }

    func envelope(version: ICloudFieldVersion) throws -> ICloudRecordEnvelope {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        guard payload.count <= Self.maximumBytes else { throw ICloudRetentionError.malformedSnapshot }
        return try .init(kind: .retentionQuota, recordName: Self.recordName,
            fields: ["ledger": .init(value: .text(String(decoding: payload, as: UTF8.self)), version: version)])
    }

    static func decode(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maximumBytes,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["schemaVersion", "clockStamp", "reservations"].allSatisfy({ json[$0] != nil }),
              Set(json.keys).isSubset(of: ["schemaVersion", "clockStamp", "lastServerDate", "reservations"]),
              let entries = json["reservations"] as? [[String: Any]], entries.count <= ICloudRetentionWeek.recordLimit else {
            throw ICloudRetentionError.malformedSnapshot
        }
        for entry in entries {
            guard entry["operationID"] != nil, entry["processedRecords"] != nil,
                  Set(entry.keys).isSubset(of: ["operationID", "processedRecords", "confirmedAt"]) else {
                throw ICloudRetentionError.malformedSnapshot
            }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    init(envelope: ICloudRecordEnvelope) throws {
        try envelope.validate()
        guard envelope.kind == .retentionQuota, case .text(let text) = envelope.fields["ledger"]?.value else {
            throw ICloudRetentionError.malformedSnapshot
        }
        self = try Self.decode(text)
    }

    static func validateWireData(_ data: Data) throws {
        guard data.count <= maximumBytes * 2 + 1_024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == ["schemaVersion", "kind", "recordName", "fields"],
              let fields = json["fields"] as? [String: Any], Set(fields.keys) == ["ledger"],
              let ledger = fields["ledger"] as? [String: Any], Set(ledger.keys) == ["value", "version"],
              let version = ledger["version"] as? [String: Any], Set(version.keys) == ["counter", "deviceID"],
              let value = ledger["value"] as? [String: Any], Set(value.keys) == ["text"],
              let text = value["text"] as? [String: Any], Set(text.keys) == ["_0"],
              let payload = text["_0"] as? String else { throw ICloudRetentionError.malformedSnapshot }
        _ = try decode(payload)
    }

    private static func validDate(_ date: Date?) -> Bool {
        date.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 } ?? true
    }
    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString == value
    }
}
