@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudGenerationZoneTests: XCTestCase {
    private let first = "00000000-0000-0000-0000-000000000001"
    private let second = "00000000-0000-0000-0000-000000000002"

    private func envelope() throws -> ICloudRecordEnvelope {
        let url = URL(string: "https://example.com/rss")!
        let name = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: "opaque:ID"))
        return try .init(kind: .read, recordName: "read-v1:" + name.dropFirst("article-v1:".count),
            feedURL: url.absoluteString, sourceItemID: "opaque:ID",
            fields: ["value": .init(value: .flag(true), version: .init(counter: 1, deviceID: first))])
    }

    func testPhysicalZonesDifferAcrossEpochsAndPreserveLogicalKinds() throws {
        for zone in ICloudRecordZone.allCases {
            let a = try ICloudGenerationZone.id(zone, generation: first)
            let b = try ICloudGenerationZone.id(zone, generation: second)
            XCTAssertNotEqual(a, b)
            XCTAssertEqual(try ICloudGenerationZone.classify(a, generation: first), .current(zone))
            XCTAssertEqual(try ICloudGenerationZone.classify(a, generation: second), .otherGeneration(zone))
            XCTAssertEqual(try ICloudGenerationZone.currentZone(b, generation: second), zone)
            XCTAssertNil(try ICloudGenerationZone.currentZone(a, generation: second))
            XCTAssertNotEqual(a, ICloudCloudRootCodec.zoneID)
        }
    }

    func testLegacyAndUnrelatedZonesNeverClassifyAsCurrent() throws {
        for zone in ICloudRecordZone.allCases {
            XCTAssertEqual(try ICloudGenerationZone.classify(ICloudRecordCodec.zoneID(zone), generation: first), .legacy(zone))
        }
        XCTAssertEqual(try ICloudGenerationZone.classify(ICloudCloudRootCodec.zoneID, generation: first), .unrelated)
        XCTAssertEqual(try ICloudGenerationZone.classify(.default, generation: first), .unrelated)
        let foreignOwner = CKRecordZone.ID(zoneName: try ICloudGenerationZone.id(.library, generation: first).zoneName,
                                          ownerName: "another-owner")
        XCTAssertEqual(try ICloudGenerationZone.classify(foreignOwner, generation: first), .unrelated)
    }

    func testMalformedOwnedNamesRequireReviewButDoNotBecomeCurrent() throws {
        for suffix in ["", "invalid", first.lowercased() + "-extra"] {
            let name = ICloudRecordZone.library.rawValue + "-epoch-" + suffix
            XCTAssertTrue(ICloudGenerationZone.isOwnedDataZoneName(name))
            XCTAssertThrowsError(try ICloudGenerationZone.classify(.init(zoneName: name, ownerName: CKCurrentUserDefaultName),
                                                                 generation: first))
        }
        XCTAssertThrowsError(try ICloudGenerationZone.id(.articles, generation: "invalid"))
        XCTAssertFalse(ICloudGenerationZone.isOwnedDataZoneName("another-app"))
        XCTAssertFalse(ICloudGenerationZone.isOwnedDataZoneName(ICloudCloudRootCodec.zoneID.zoneName))
    }

    func testRecordCodecRequiresBothTheEpochRecordNameAndPhysicalZone() throws {
        let value = try envelope()
        let record = try ICloudRecordCodec.encode(value, systemFields: nil, generation: first)
        XCTAssertEqual(record.recordID.zoneID, try ICloudGenerationZone.id(.articles, generation: first))
        XCTAssertEqual(try ICloudRecordCodec.decode(record, generation: first), value)
        XCTAssertEqual(try ICloudRecordCodec.received(record, generation: first).envelope.sourceItemID, "opaque:ID")
        XCTAssertThrowsError(try ICloudRecordCodec.decode(record, generation: second))
        let impostor = CKRecord(recordType: ICloudRecordCodec.recordType,
            recordID: .init(recordName: record.recordID.recordName, zoneID: ICloudRecordCodec.zoneID(.articles)))
        impostor["envelope"] = record["envelope"]
        XCTAssertThrowsError(try ICloudRecordCodec.decode(impostor, generation: first))
        let wrongLogicalZone = CKRecord(recordType: ICloudRecordCodec.recordType,
            recordID: .init(recordName: record.recordID.recordName, zoneID: try ICloudGenerationZone.id(.library, generation: first)))
        wrongLogicalZone["envelope"] = record["envelope"]
        XCTAssertThrowsError(try ICloudRecordCodec.decode(wrongLogicalZone, generation: first))
    }

    func testFixedZoneSystemFieldsCannotBeReusedForQualifiedZone() throws {
        let legacy = try ICloudRecordCodec.encode(envelope(), systemFields: nil)
        XCTAssertThrowsError(try ICloudRecordCodec.encode(envelope(), systemFields: ICloudRecordCodec.systemFields(legacy),
                                                        generation: first))
    }

    func testFetchScopeIncludesOnlyCurrentDataAndControlZones() throws {
        let options = try ICloudGenerationZone.fetchOptions(.init(), generation: second)
        for zone in ICloudRecordZone.allCases {
            XCTAssertTrue(try options.scope.contains(ICloudGenerationZone.id(zone, generation: second)))
            XCTAssertFalse(try options.scope.contains(ICloudGenerationZone.id(zone, generation: first)))
            XCTAssertFalse(options.scope.contains(ICloudRecordCodec.zoneID(zone)))
        }
        XCTAssertTrue(options.scope.contains(ICloudCloudRootCodec.zoneID))
        XCTAssertFalse(options.scope.contains(.default))
    }

    func testFetchScopePreservesCallerExclusionsPrioritiesAndOperationGroup() throws {
        let current = try ICloudGenerationZone.id(.articles, generation: second)
        let old = try ICloudGenerationZone.id(.articles, generation: first)
        let group = CKOperationGroup()
        group.name = "generation-scope-test"
        var requested = CKSyncEngine.FetchChangesOptions(scope: .allExcluding([current]), operationGroup: group)
        requested.prioritizedZoneIDs = [old, current, ICloudCloudRootCodec.zoneID]
        let scoped = try ICloudGenerationZone.fetchOptions(requested, generation: second)
        XCTAssertFalse(scoped.scope.contains(current))
        XCTAssertFalse(scoped.scope.contains(old))
        XCTAssertEqual(scoped.prioritizedZoneIDs, [ICloudCloudRootCodec.zoneID])
        XCTAssertEqual(scoped.operationGroup.operationGroupID, group.operationGroupID)
        XCTAssertEqual(scoped.operationGroup.name, group.name)
        let exact = try ICloudGenerationZone.fetchOptions(.init(scope: .zoneIDs([current])), generation: second)
        XCTAssertTrue(exact.scope.contains(current))
        XCTAssertFalse(exact.scope.contains(ICloudCloudRootCodec.zoneID))
    }

    func testOldCheckpointZoneChangesCannotDeleteOrRecreateCurrentZones() throws {
        let current = try ICloudGenerationZone.id(.library, generation: second)
        let old = try ICloudGenerationZone.id(.library, generation: first)
        let legacy = ICloudRecordCodec.zoneID(.library)
        let keep = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: current))
        let changes: [CKSyncEngine.PendingDatabaseChange] = [
            keep, .saveZone(CKRecordZone(zoneID: old)), .saveZone(CKRecordZone(zoneID: legacy)),
            .deleteZone(current), .deleteZone(old), .deleteZone(ICloudCloudRootCodec.zoneID),
            .saveZone(CKRecordZone(zoneID: .default))
        ]
        let rejected = try ICloudGenerationZone.obsoleteDatabaseChanges(changes, generation: second)
        XCTAssertEqual(rejected.count, changes.count - 1)
        XCTAssertFalse(rejected.contains(keep))
    }

    func testRecordCheckpointChangesAreScopedAndNormalSyncHasNoPhysicalDeletes() throws {
        let current = try ICloudRecordCodec.recordID(envelope(), generation: second)
        let old = try ICloudRecordCodec.recordID(envelope(), generation: first)
        let legacy = try ICloudRecordCodec.recordID(envelope())
        let wrongZone = CKRecord.ID(recordName: current.recordName, zoneID: legacy.zoneID)
        let wrongName = CKRecord.ID(recordName: old.recordName, zoneID: current.zoneID)
        let keep = CKSyncEngine.PendingRecordZoneChange.saveRecord(current)
        let changes: [CKSyncEngine.PendingRecordZoneChange] = [
            keep, .saveRecord(old), .saveRecord(legacy), .saveRecord(wrongZone), .saveRecord(wrongName),
            .deleteRecord(current), .deleteRecord(old)
        ]
        let rejected = try ICloudGenerationZone.obsoleteRecordChanges(changes, generation: second)
        XCTAssertEqual(rejected.count, changes.count - 1)
        XCTAssertFalse(rejected.contains(keep))
    }

    func testDelayedDeleteAndSaveCannotTouchNewEpochData() throws {
        let old = try ICloudGenerationZone.id(.articles, generation: first)
        let fresh = try ICloudGenerationZone.id(.articles, generation: second)
        var physical: [CKRecordZone.ID: Set<String>] = [old: ["old"], fresh: ["new"]]
        // A queued delete from the old reset arrives after the new epoch exists.
        physical.removeValue(forKey: old)
        XCTAssertEqual(physical[fresh], ["new"])
        // An old queued creation/save can leave residue only under its old ID.
        physical[old] = ["late-old"]
        XCTAssertEqual(physical[fresh], ["new"])
        XCTAssertNil(try ICloudGenerationZone.currentZone(old, generation: second))
        XCTAssertEqual(try ICloudGenerationZone.foreignZoneCount(Array(physical.keys), generation: second), 1)
    }

    func testForeignZoneStatisticsCountZonesWithoutClaimingTheirRecordCounts() throws {
        let ids = try [
            ICloudGenerationZone.id(.library, generation: second),
            ICloudGenerationZone.id(.articles, generation: second),
            ICloudGenerationZone.id(.library, generation: first),
            ICloudGenerationZone.id(.articles, generation: first)
        ] + [ICloudRecordCodec.zoneID(.library), ICloudCloudRootCodec.zoneID, .default]
        XCTAssertEqual(try ICloudGenerationZone.foreignZoneCount(ids, generation: second), 3)
        let inventory = ICloudMaintenancePlanner.inventory(records: [], isComplete: true,
            reachedSafetyLimit: false, syncUnreadContent: false, protection: .init(), otherGenerationZones: 3)
        XCTAssertEqual(inventory.otherGenerationZones, 3)
        XCTAssertEqual(inventory.recordCount, 0)
        XCTAssertEqual(inventory.cleanupPreview?.proposedRecordCount, 0)
    }

    func testScannerDoesNotDoubleCountZoneInventoryFromDifferentPages() async throws {
        actor Pages: ICloudInventoryPageFetching {
            func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
                .init(records: [], cursor: nil, envelopeBytes: 0, otherGenerationZones: 4)
            }
        }
        let scanner = ICloudInventoryScanner(source: Pages())
        _ = try await scanner.scan()
        let count = await scanner.foreignZoneCount, complete = await scanner.isComplete
        XCTAssertEqual(count, 4)
        XCTAssertTrue(complete)
    }

    func testVersionOneRootIsRejectedWithoutSilentlyChangingItsLayout() throws {
        let record = try ICloudCloudRootCodec.encode(.init(generation: first, phase: .ready))
        XCTAssertEqual(record["schemaVersion"] as? Int, 2)
        record["schemaVersion"] = 1 as NSNumber
        XCTAssertThrowsError(try ICloudCloudRootCodec.decode(record)) {
            XCTAssertEqual($0 as? ICloudRootError, .unsupportedVersion)
        }
        XCTAssertEqual(record["schemaVersion"] as? Int, 1)
    }
}
