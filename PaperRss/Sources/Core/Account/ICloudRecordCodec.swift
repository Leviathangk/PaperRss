@preconcurrency import CloudKit
import Darwin
import Foundation

/// CKRecord system fields preserve the server change tag. The engine uses
/// ifServerRecordUnchanged; callers merge the returned server record on conflict.
enum ICloudRecordCodec {
    static let recordType = "PaperRssRecordV1"
    static let maximumEnvelopeBytes = 512 * 1024

    static func encode(_ envelope: ICloudRecordEnvelope, systemFields: Data?, bodyData: Data? = nil, assetURL: URL? = nil, generation: String? = nil) throws -> CKRecord {
        try envelope.validate()
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= maximumEnvelopeBytes else { throw ICloudRecordError.malformedRecord }
        if envelope.kind == .retention { try ICloudRetentionFence.validateWireData(data) }
        if envelope.kind == .retentionPolicy { try ICloudRetentionUnreadPolicy.validateWireData(data) }
        if envelope.kind == .retentionQuota { try ICloudRetentionQuota.validateWireData(data) }
        let id = try recordID(envelope, generation: generation)
        let record: CKRecord
        if let systemFields {
            let coder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            guard let restored = CKRecord(coder: coder), restored.recordID == id,
                  restored.recordType == recordType else { throw ICloudRecordError.identityMismatch }
            record = restored
        } else {
            record = CKRecord(recordType: recordType, recordID: id)
        }
        record["envelope"] = data as NSData
        record["content"] = nil
        record["contentAsset"] = nil
        if envelope.kind == .content, case .text(let hash) = envelope.fields["payload_hash"]?.value {
            guard let bodyData, bodyData.count <= ICloudArticleContentCodec.maximumCompressedBytes,
                  ICloudArticleContentCodec.hash(bodyData) == hash else { throw ICloudRecordError.malformedRecord }
            if bodyData.count <= ICloudArticleContentCodec.inlineBytes {
                record["content"] = bodyData as NSData
            } else {
                guard let assetURL else { throw ICloudRecordError.malformedRecord }
                record["contentAsset"] = CKAsset(fileURL: assetURL)
            }
        } else if bodyData != nil { throw ICloudRecordError.malformedRecord }
        return record
    }

    static func decode(_ record: CKRecord, generation: String? = nil) throws -> ICloudRecordEnvelope {
        guard record.recordType == recordType, let data = record["envelope"] as? Data,
              data.count <= maximumEnvelopeBytes else { throw ICloudRecordError.malformedRecord }
        let envelope = try JSONDecoder().decode(ICloudRecordEnvelope.self, from: data)
        try envelope.validate()
        if envelope.kind == .retention { try ICloudRetentionFence.validateWireData(data) }
        if envelope.kind == .retentionPolicy { try ICloudRetentionUnreadPolicy.validateWireData(data) }
        if envelope.kind == .retentionQuota { try ICloudRetentionQuota.validateWireData(data) }
        guard try recordID(envelope, generation: generation) == record.recordID else { throw ICloudRecordError.identityMismatch }
        return envelope
    }

    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func received(_ record: CKRecord, generation: String? = nil) throws -> ICloudReceivedRecord {
        let envelope = try decode(record, generation: generation)
        let data: Data?
        if envelope.kind == .content, case .text(let hash) = envelope.fields["payload_hash"]?.value {
            if let inline = record["content"] as? Data {
                guard inline.count <= ICloudArticleContentCodec.inlineBytes, record["contentAsset"] == nil
                else { throw ICloudRecordError.malformedRecord }
                data = inline
            } else if let asset = record["contentAsset"] as? CKAsset, let url = asset.fileURL {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= ICloudArticleContentCodec.maximumCompressedBytes else { throw ICloudRecordError.malformedRecord }
                data = try Data(contentsOf: url)
            } else { throw ICloudRecordError.malformedRecord }
            _ = try ICloudArticleContentCodec.decode(data!, expectedHash: hash)
        } else {
            guard record["content"] == nil, record["contentAsset"] == nil else { throw ICloudRecordError.malformedRecord }
            data = nil
        }
        return .init(envelope: envelope, systemFields: systemFields(record), bodyData: data)
    }

    static func zoneID(_ zone: ICloudRecordZone) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(_ envelope: ICloudRecordEnvelope, generation: String? = nil) throws -> CKRecord.ID {
        let name = try generation.map { try ICloudGenerationIdentity.recordName(envelope.recordName, generation: $0) }
            ?? envelope.recordName
        let physicalZone = try generation.map { try ICloudGenerationZone.id(envelope.zone, generation: $0) } ?? zoneID(envelope.zone)
        return CKRecord.ID(recordName: name, zoneID: physicalZone)
    }
}

/// Keep the file alive until CloudKit completes the save or cancellation.
/// Each lease owns only its random temporary directory, never SDK downloads.
final class ICloudAssetLease: Sendable {
    private static let prefix = "PaperRss-CloudAsset-"
    private static let markerName = ".owner.lock"
    private static let marker = Data("PaperRss.CloudAsset.v1".utf8)
    private static let startupCleanup: Void = {
        _ = removeAbandonedDirectories(olderThan: Date().addingTimeInterval(-24 * 60 * 60))
    }()
    let fileURL: URL
    private let directory: URL
    private let lockDescriptor: Int32

    static func cleanUpOnce() { _ = startupCleanup }

    init(data: Data, root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("content.lzfse")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent(Self.markerName).path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        lockDescriptor = descriptor
        do {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
            let written = Self.marker.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written == Self.marker.count else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            close(descriptor)
            throw error
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        close(lockDescriptor)
    }

    /// Only marked, stale, unlocked directories with the exact owned shape
    /// qualify. Never descend into SDK downloads or follow symlinks.
    static func removeAbandonedDirectories(
        at root: URL = FileManager.default.temporaryDirectory, olderThan cutoff: Date,
        maximumDirectories: Int = 8, timeBudget: Duration = .milliseconds(100)
    ) -> Int {
        guard maximumDirectories > 0, timeBudget > .zero else { return 0 }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants]) else { return 0 }
        let deadline = ContinuousClock.now.advanced(by: timeBudget)
        var removed = 0
        while removed < maximumDirectories, ContinuousClock.now < deadline,
              let directory = enumerator.nextObject() as? URL {
            let name = directory.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let values = try? directory.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  let date = values.contentModificationDate, date < cutoff,
                  let children = try? FileManager.default.contentsOfDirectory(at: directory,
                      includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
                  Set(children.map(\.lastPathComponent)).isSubset(of: [markerName, "content.lzfse"]),
                  children.contains(where: { $0.lastPathComponent == markerName }),
                  children.allSatisfy({ child in
                      guard let resource = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                      else { return false }
                      return resource.isSymbolicLink != true && resource.isRegularFile == true
                  }) else { continue }
            let descriptor = open(directory.appendingPathComponent(markerName).path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: marker.count + 1)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count == marker.count, Data(bytes.prefix(count)) == marker else { continue }
            do {
                try FileManager.default.removeItem(at: directory)
                removed += 1
            } catch { /* Retry on a later launch; no paths or article data are logged. */ }
        }
        return removed
    }
}
