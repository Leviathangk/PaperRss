#if os(macOS)
import AppKit
import Combine
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// Silent CloudKit delivery is independent of the app's user-visible feed
/// alerts. Never log the device token or a notification payload.
@MainActor
final class ICloudApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var store: AppStore?
    private var accountsObservation: AnyCancellable?
    private var registrationPending = false
    private var registered = false

    func connect(store: AppStore) {
        guard self.store !== store else { return }
        self.store = store
        accountsObservation = store.$accounts.sink { [weak self] _ in
            // Published's callback precedes assignment; inspect on the next turn.
            Task { @MainActor [weak self] in self?.registerIfNeeded() }
        }
        registerIfNeeded()
    }

    private func registerIfNeeded() {
        guard let store, store.supportsICloudSync,
              store.accounts.contains(where: { $0.type == AccountType.iCloud.rawValue && $0.isEnabled }),
              !registrationPending, !registered else { return }
        registrationPending = true
        NSApplication.shared.registerForRemoteNotifications()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        registerIfNeeded()
        Task { await store?.resumeICloudAutomaticSync() }
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Announce pending metadata before leaving the foreground. CKSyncEngine
        // owns the actual schedule and network recovery, with no RSS refetch.
        Task { await store?.resumeICloudAutomaticSync(fetchRemote: false) }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registered = true
        registrationPending = false
        store?.setICloudPushRegistrationAvailable(true)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        registrationPending = false
        store?.setICloudPushRegistrationAvailable(false)
    }
}
#endif
