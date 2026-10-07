import Foundation
import XCTest
@testable import PaperRssCore

final class ICloudAssetRecoveryTests: XCTestCase {
    private var root: URL!
    private let old = Date(timeIntervalSince1970: 100)
    private let cutoff = Date(timeIntervalSince1970: 200)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AssetRecoveryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    private func staleDirectory(marker: String? = "PaperRss.CloudAsset.v1", body: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent("PaperRss-CloudAsset-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        if let marker { try Data(marker.utf8).write(to: directory.appendingPathComponent(".owner.lock")) }
        if body { try Data([1, 2, 3]).write(to: directory.appendingPathComponent("content.lzfse")) }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        return directory
    }
    private func collect(_ maximum: Int = 8) -> Int {
        ICloudAssetLease.removeAbandonedDirectories(at: root, olderThan: cutoff,
            maximumDirectories: maximum, timeBudget: .seconds(2))
    }

    func testStaleOwnedFilesAreRecoveredWhileFreshAndUnmarkedFilesAreRetained() throws {
        let abandoned = try staleDirectory()
        let missingBody = try staleDirectory(body: false)
        let fresh = try staleDirectory()
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fresh.path)
        let unmarked = try staleDirectory(marker: nil)
        let wrongMarker = try staleDirectory(marker: "AnotherOwner")
        XCTAssertEqual(collect(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingBody.path))
        for directory in [fresh, unmarked, wrongMarker] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testActiveUploadLockAndPrivatePermissionsSurviveRecovery() throws {
        var lease: ICloudAssetLease? = try ICloudAssetLease(data: Data([4, 5]), root: root)
        let file = try XCTUnwrap(lease?.fileURL)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        XCTAssertEqual(collect(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? Int, 0o600)
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRecoveryDoesNotFollowSymlinksOrDeleteUnexpectedContents() throws {
        let target = root.appendingPathComponent("sdk-download")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let download = target.appendingPathComponent("download")
        try Data([8]).write(to: download)
        let link = root.appendingPathComponent("PaperRss-CloudAsset-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let unexpected = try staleDirectory()
        try Data([9]).write(to: unexpected.appendingPathComponent("unrelated"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unexpected.path)
        let linkedBody = try staleDirectory(body: false)
        try FileManager.default.createSymbolicLink(at: linkedBody.appendingPathComponent("content.lzfse"), withDestinationURL: download)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: linkedBody.path)
        XCTAssertEqual(collect(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedBody.path))
    }

    func testRecoveryHonorsDirectoryAndTimeBudgets() throws {
        for _ in 0..<7 { _ = try staleDirectory() }
        XCTAssertEqual(collect(3), 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 4)
        XCTAssertEqual(ICloudAssetLease.removeAbandonedDirectories(at: root, olderThan: cutoff,
            timeBudget: .zero), 0)
        XCTAssertEqual(collect(0), 0)
        XCTAssertEqual(collect(), 4)
    }
}
