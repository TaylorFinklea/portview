// SPDX-License-Identifier: Apache-2.0
import UIKit
import UserNotifications

/// The §2a silent-push plumbing that a pure-SwiftUI app lacks: APNs registration at launch (a
/// CloudKit subscription push rides APNs even with no server token exchange), the notification-
/// center delegate assigned BEFORE launch completes (or a tap that launches the terminated app is
/// dropped), and the background `didReceiveRemoteNotification` callback — the only place a
/// content-available push can land. Installed via `@UIApplicationDelegateAdaptor`.
@MainActor
final class ReWakeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // §2a.5 — the center delegate must be set before launch completes.
        UNUserNotificationCenter.current().delegate = self
        // §2a.3 — CloudKit subscription pushes require APNs registration.
        application.registerForRemoteNotifications()
        ReWakeCenter.shared.onLaunch()
        // The zone/subscription bootstrap retries on every foreground return (phone-first install
        // order leaves it not-ready until the Mac writes its first beacon).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await ReWakeCenter.shared.refresh() }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Soft-fail: re-wake is a best-effort accelerator; registration is retried by the system.
    }

    /// §2a.4 — the silent-push landing spot. The completion handler is guaranteed on EVERY path
    /// (the classic silent-push killer is a missed one): the single `Task` below is the method's
    /// only exit, and `handlePush` is total, non-throwing, and hard-deadlined well inside the
    /// ~30 s background budget — so `completionHandler` is always reached, exactly once.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let isForeground = application.applicationState == .active
        Task { @MainActor in
            let outcome = await ReWakeCenter.shared.handlePush(isForeground: isForeground)
            completionHandler(outcome.fetchResult)
        }
    }
}

extension ReWakeBackgroundHandler.Outcome {
    var fetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}

extension ReWakeAppDelegate: UNUserNotificationCenterDelegate {
    /// Notification tap → deep-link into the existing saved-Mac reconnect flow: publish the pin
    /// hex the notification carries; ContentView routes it through `SavedHost.reconnectEndpoints`
    /// (Bonjour re-resolve preferred over the possibly-stale saved IP).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let pinHex = response.notification.request.content.userInfo[ReWakeCenter.notificationPinHexKey] as? String
        Task { @MainActor in
            if let pinHex {
                ReWakeCenter.shared.pendingReconnectPinHex = pinHex
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A push that arrives while foreground already routes straight into the in-app reconnect —
        // never banner over live UI.
        completionHandler([])
    }
}
