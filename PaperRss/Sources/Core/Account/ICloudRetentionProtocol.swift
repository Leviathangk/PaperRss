import Foundation

enum ICloudRetentionError: Error, Sendable, Equatable {
    case malformedFence, unsupportedProtocol, wrongGeneration, malformedSnapshot
    case incompleteSnapshot, unresolvedChanges, budgetExceeded, clockOverflow
}

/// Portable retirement floors. Only hashed identities, generation and versions
/// are persisted here: no GUID, URL, body, local article ID or user fingerprint.
/// A floor suppresses old confirmed data. Actual pending user intents must be
/// rebased separately rather than silently discarded as an expired cache.
struct ICloudRetentionFence: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generation: String
    let recordName: String
    let feedRecordName: String
    var readFloor: ICloudFieldVersion?
    var starredFloor: ICloudFieldVersion?
    var contentFloor: ICloudFieldVersion?

    static let maximumBytes = 2_048

    init(generation: String, article: ICloudRecordEnvelope) throws {
        try article.validate()
        guard [.read, .starred, .content].contains(article.kind),
              let url = article.feedURL.flatMap(URL.init(string:)) else {
            throw ICloudRetentionError.malformedFence
        }
        schemaVersion = 1
        self.generation = generation
        recordName = "retention-v1:" + ICloudMaintenancePlanner.articleKey(article.recordName)
        feedRecordName = try ICloudSyncIdentity.feedRecordName(feedURL: url)
        try validate()
    }

    init(envelope: ICloudRecordEnvelope, generation: String) throws {
        try envelope.validate()
        guard envelope.kind == .retention, let feed = envelope.feedRecordName else {
            throw ICloudRetentionError.malformedFence
        }
        schemaVersion = 1; self.generation = generation
        recordName = envelope.recordName; feedRecordName = feed
        readFloor = envelope.fields["read_floor"].flatMap { $0.value == .flag(true) ? $0.version : nil }
        starredFloor = envelope.fields["starred_floor"].flatMap { $0.value == .flag(true) ? $0.version : nil }
        contentFloor = envelope.fields["content_floor"].flatMap { $0.value == .flag(true) ? $0.version : nil }
        try validate()
    }

    func envelope() throws -> ICloudRecordEnvelope {
        try validate()
        var fields: [String: ICloudVersionedField] = [:]
        for (key, floor) in [("read_floor", readFloor), ("starred_floor", starredFloor), ("content_floor", contentFloor)] {
            fields[key] = .init(value: .flag(floor != nil), version: floor ?? .bootstrap)
        }
        fields["writer_nonce"] = .init(value: .text(""), version: .bootstrap)
        return try .init(kind: .retention, recordName: recordName, feedRecordName: feedRecordName, fields: fields)
    }

    /// The generic decoder tolerates future top-level keys for older records;
    /// the hash-only retention contract deliberately has a strict whitelist.
    static func validateWireData(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "kind", "recordName", "feedRecordName", "fields"],
              let fields = root["fields"] as? [String: Any],
              Set(fields.keys) == ["read_floor", "starred_floor", "content_floor", "writer_nonce"] else {
            throw ICloudRetentionError.malformedFence
        }
        for (key, value) in fields {
            let payloadKind = key == "writer_nonce" ? "text" : "flag"
            guard let field = value as? [String: Any], Set(field.keys) == ["value", "version"],
                  let version = field["version"] as? [String: Any], Set(version.keys) == ["counter", "deviceID"],
                  let wrapped = field["value"] as? [String: Any], Set(wrapped.keys) == [payloadKind],
                  let payload = wrapped[payloadKind] as? [String: Any], Set(payload.keys) == ["_0"] else {
                throw ICloudRetentionError.malformedFence
            }
        }
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw ICloudRetentionError.unsupportedProtocol }
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        guard Self.hashedName(recordName, prefix: "retention-v1:"),
              Self.hashedName(feedRecordName, prefix: "feed-v1:") else {
            throw ICloudRetentionError.malformedFence
        }
        for version in [readFloor, starredFloor, contentFloor].compactMap({ $0 }) {
            guard version.counter >= 0,
                  version.counter == 0 ? version.deviceID.isEmpty : UUID(uuidString: version.deviceID) != nil else {
                throw ICloudRetentionError.malformedFence
            }
        }
    }

    func floor(for kind: ICloudRecordKind) throws -> ICloudFieldVersion? {
        switch kind {
        case .read: return readFloor
        case .starred: return starredFloor
        case .content: return contentFloor
        default: throw ICloudRetentionError.malformedFence
        }
    }

    func suppresses(_ envelope: ICloudRecordEnvelope) throws -> Bool {
        try validate(); try requireIdentity(envelope)
        let key = envelope.kind == .content ? "payload_hash" : "value"
        guard let version = envelope.fields[key]?.version else { throw ICloudRetentionError.malformedFence }
        return try floor(for: envelope.kind).map { version <= $0 } ?? false
    }

    func retiring(_ records: [ICloudRecordEnvelope]) throws -> Self {
        try validate()
        var result = self
        for record in records {
            try requireIdentity(record)
            let key = record.kind == .content ? "payload_hash" : "value"
            let version = record.fields[key]!.version
            switch record.kind {
            case .read: result.readFloor = Self.maximum(result.readFloor, version)
            case .starred: result.starredFloor = Self.maximum(result.starredFloor, version)
            case .content: result.contentFloor = Self.maximum(result.contentFloor, version)
            default: throw ICloudRetentionError.malformedFence
            }
        }
        try result.validate()
        return result
    }

    func merged(with other: Self) throws -> Self {
        try validate(); try other.validate()
        guard generation == other.generation else { throw ICloudRetentionError.wrongGeneration }
        guard recordName == other.recordName, feedRecordName == other.feedRecordName else {
            throw ICloudRetentionError.malformedFence
        }
        var result = self
        result.readFloor = Self.maximum(readFloor, other.readFloor)
        result.starredFloor = Self.maximum(starredFloor, other.starredFloor)
        result.contentFloor = Self.maximum(contentFloor, other.contentFloor)
        return result
    }

    /// Call only for an actual pending user intent. An acknowledged old cache
    /// or automatic baseline is not a new operation and must not use this API.
    func versionForPendingIntent(kind: ICloudRecordKind, current: ICloudFieldVersion,
                                 observedClock: Int64, deviceID: String) throws -> ICloudFieldVersion {
        try validate()
        guard current.counter >= 0, observedClock >= 0, UUID(uuidString: deviceID) != nil,
              current.counter == 0 ? current.deviceID.isEmpty : UUID(uuidString: current.deviceID) != nil else {
            throw ICloudRetentionError.malformedFence
        }
        guard let floor = try floor(for: kind), current <= floor else { return current }
        let counter = max(observedClock, max(current.counter, floor.counter))
        guard counter < Int64.max else { throw ICloudRetentionError.clockOverflow }
        return .init(counter: counter + 1, deviceID: deviceID)
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ICloudRetentionError.malformedFence }
        return data
    }

    static func decode(_ data: Data, generation: String) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ICloudRetentionError.malformedFence
        }
        let required: Set<String> = ["schemaVersion", "generation", "recordName", "feedRecordName"]
        let optional: Set<String> = ["readFloor", "starredFloor", "contentFloor"]
        let keys = Set(fields.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw ICloudRetentionError.malformedFence
        }
        for key in optional {
            guard let field = fields[key], !(field is NSNull) else { continue }
            guard let version = field as? [String: Any], Set(version.keys) == ["counter", "deviceID"] else {
                throw ICloudRetentionError.malformedFence
            }
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        guard result.generation == generation else { throw ICloudRetentionError.wrongGeneration }
        return result
    }

    private func requireIdentity(_ envelope: ICloudRecordEnvelope) throws {
        let identity = try Self(generation: generation, article: envelope)
        guard recordName == identity.recordName, feedRecordName == identity.feedRecordName else {
            throw ICloudRetentionError.malformedFence
        }
    }
    private static func maximum(_ a: ICloudFieldVersion?, _ b: ICloudFieldVersion?) -> ICloudFieldVersion? {
        if let a, let b { return max(a, b) }
        return a ?? b
    }
    private static func hashedName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.count == 64 && suffix.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

/// Historical preview aggregate, not an execution quota or a local timer.
/// The shared cleaner uses ICloudRetentionQuota reservations to enforce a
/// rolling seven-day window; this aggregate cannot represent that window.
struct ICloudRetentionWeek: Sendable, Equatable {
    let startedAt: Date
    let processedRecords: Int
    static let duration: TimeInterval = 7 * 24 * 60 * 60
    static let recordLimit = 400

    func allocating(_ records: Int, serverNow: Date) throws -> Self {
        guard startedAt.timeIntervalSince1970.isFinite, serverNow.timeIntervalSince1970.isFinite,
              serverNow >= startedAt, processedRecords >= 0, processedRecords <= Self.recordLimit,
              records > 0, records <= Self.recordLimit else { throw ICloudRetentionError.malformedSnapshot }
        let newWeek = serverNow.timeIntervalSince(startedAt) >= Self.duration
        let used = newWeek ? 0 : processedRecords
        guard records <= Self.recordLimit - used else { throw ICloudRetentionError.budgetExceeded }
        return .init(startedAt: newWeek ? serverNow : startedAt, processedRecords: used + records)
    }
}

/// This is a candidate with required CAS guards, not an execution approval or
/// an SDK delete batch. Normal writers/receivers, root compatibility gating,
/// durable server quota and an atomic transport must be integrated first.
struct ICloudRetentionCandidate: Sendable {
    let fence: ICloudRetentionFence
    let observedRecords: [ICloudCloudRecordMetadata]
    let recordsToRemove: [String]
    let requiresUnreadPolicyGuard: Bool
    /// Include article-fence, weekly-budget and (when needed) policy-guard saves
    /// in the approved 400-record ceiling, rather than hiding their overhead.
    var processedRecordCount: Int { recordsToRemove.count + 2 + (requiresUnreadPolicyGuard ? 1 : 0) }
}

enum ICloudRetentionPlanner {
    static func candidates(records: [ICloudCloudRecordMetadata], generation: String,
        isComplete: Bool, syncUnreadContent: Bool, protection: ICloudMaintenanceProtection,
        existingFences: [ICloudRetentionFence] = [], serverNow: Date,
        remainingRecords: Int = ICloudRetentionWeek.recordLimit) throws -> [ICloudRetentionCandidate] {
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        guard isComplete else { throw ICloudRetentionError.incompleteSnapshot }
        guard !protection.hasUnresolvedChanges else { throw ICloudRetentionError.unresolvedChanges }
        guard serverNow.timeIntervalSince1970.isFinite,
              remainingRecords >= 0, remainingRecords <= ICloudRetentionWeek.recordLimit else {
            throw ICloudRetentionError.malformedSnapshot
        }
        var grouped: [String: [ICloudRecordKind: ICloudCloudRecordMetadata]] = [:]
        for record in records {
            try record.envelope.validate()
            guard [.read, .starred, .content].contains(record.envelope.kind) else { continue }
            let key = ICloudMaintenancePlanner.articleKey(record.envelope.recordName)
            if let old = grouped[key]?[record.envelope.kind] {
                guard old.envelope == record.envelope, old.changeTag == record.changeTag,
                      old.systemFields == record.systemFields, old.creationDate == record.creationDate,
                      old.modificationDate == record.modificationDate else { throw ICloudRetentionError.malformedSnapshot }
            }
            grouped[key, default: [:]][record.envelope.kind] = record
        }
        var fences: [String: ICloudRetentionFence] = [:]
        for fence in existingFences {
            try fence.validate()
            guard fence.generation == generation else { throw ICloudRetentionError.wrongGeneration }
            fences[fence.recordName] = try fences[fence.recordName]?.merged(with: fence) ?? fence
        }
        let protected = Set(protection.recordNames.map(ICloudMaintenancePlanner.articleKey))
        let cutoff = serverNow.addingTimeInterval(-ICloudMaintenancePlanner.proposedRetention)
        var result: [ICloudRetentionCandidate] = [], remaining = remainingRecords
        for key in grouped.keys.sorted() {
            let group = grouped[key]!
            let observed = [ICloudRecordKind.read, .starred, .content].compactMap { group[$0] }
            var fence = try ICloudRetentionFence(generation: generation, article: observed[0].envelope)
            if let previous = fences[fence.recordName] { fence = try fence.merged(with: previous) }
            // Reject mixed identities even if their record-name hashes match.
            _ = try fence.retiring(observed.map(\.envelope))
            guard !protected.contains(key), !protection.recordNames.contains(fence.feedRecordName) else { continue }
            // A complete query with no CAS metadata is still only a preview.
            guard observed.allSatisfy({ record in
                guard let tag = record.changeTag, !tag.isEmpty, tag.utf8.count <= 4_096,
                      let fields = record.systemFields, !fields.isEmpty, fields.count <= 64 * 1_024 else { return false }
                return true
            }) else { continue }
            let replayed = try observed.filter { try fence.suppresses($0.envelope) }
            let replayedKinds = Set(replayed.map { $0.envelope.kind })
            let active = group.filter { !replayedKinds.contains($0.key) }
            let read = flag(active[.read]), starred = flag(active[.starred])
            let orphan = active[.read] == nil && active[.starred] == nil
            let knownUnstarred = starred == false && read != nil
            let permitsRemoval = starred != true && (orphan || (knownUnstarred && (read == true || !syncUnreadContent)))
            // A late replay below an existing floor is already retired. Its
            // new server date or old true-star value cannot revive it.
            var removals = replayed
            if permitsRemoval, let body = active[.content], orphan || hasBody(body) { removals.append(body) }
            if permitsRemoval, knownUnstarred, old(active[.read], cutoff: cutoff), old(active[.starred], cutoff: cutoff) {
                removals += [active[.read]!, active[.starred]!]
                // A compact content tombstone can retire with the expired pair.
                if let body = active[.content], !removals.contains(where: { $0.envelope.kind == .content }) { removals.append(body) }
            }
            guard !removals.isEmpty else { continue }
            let candidate = ICloudRetentionCandidate(fence: try fence.retiring(removals.map(\.envelope)),
                observedRecords: observed, recordsToRemove: removals.map { $0.envelope.recordName }.sorted(),
                requiresUnreadPolicyGuard: read != true && removals.contains { !replayedKinds.contains($0.envelope.kind) })
            guard candidate.processedRecordCount <= remaining else { continue }
            result.append(candidate); remaining -= candidate.processedRecordCount
        }
        return result
    }

    private static func flag(_ record: ICloudCloudRecordMetadata?) -> Bool? {
        if case .flag(let flag) = record?.envelope.fields["value"]?.value { return flag }
        return nil
    }
    private static func hasBody(_ record: ICloudCloudRecordMetadata) -> Bool {
        if case .text = record.envelope.fields["payload_hash"]?.value { return true }
        return false
    }
    private static func old(_ record: ICloudCloudRecordMetadata?, cutoff: Date) -> Bool {
        guard let created = record?.creationDate, let modified = record?.modificationDate,
              created.timeIntervalSince1970.isFinite, modified.timeIntervalSince1970.isFinite else { return false }
        return created < cutoff && modified < cutoff
    }
}
