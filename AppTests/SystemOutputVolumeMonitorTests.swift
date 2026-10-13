import Foundation
import XCTest
@testable import PaperRssDesktop

@MainActor
final class SystemOutputVolumeMonitorTests: XCTestCase {
    func testDefaultsNotificationFromBackgroundDoesNotViolateMainActor() async {
        let monitor = SystemOutputVolumeMonitor.shared
        XCTAssertEqual(monitor.levels.count, AudioWaveSpectrum.barCount)

        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await Task.yield()

        XCTAssertTrue(monitor.levels.allSatisfy { $0.isFinite })
    }
}
