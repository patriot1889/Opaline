import BackgroundTasks
import UIKit
import UserNotifications

/// Background feed refresh and notification-tap handling.
extension AppDelegate {
    static let backgroundRefreshIdentifier =
        (Bundle.main.bundleIdentifier ?? "co.uk.adenbeckitt.opa") + ".refresh"

    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: .main
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.runBackgroundRefresh(task)
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.notifications("could not schedule background refresh: \(error)")
        }
    }

    private func runBackgroundRefresh(_ task: BGTask) {
        scheduleBackgroundRefresh()
        // Both completion paths run on main and finish the task exactly once.
        var finished = false
        let finish: (Bool) -> Void = { success in
            guard !finished else {
                return
            }
            finished = true
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = {
            DispatchQueue.main.async { finish(false) }
        }
        refreshBackgroundContent { finish(true) }
    }

    private func refreshBackgroundContent(completion: @escaping () -> Void) {
        AppLog.notifications("background refresh woke the app")
        // News check and feed warm-up share the one ~30s window. `force`:
        // the 2h throttle exists to keep foreground launches from hammering
        // the manifest, while iOS hands out these windows sparingly and on
        // its own schedule — throttling one would just waste it.
        let group = DispatchGroup()
        var newData = false
        group.enter()
        UpdateNotificationService.shared.checkIfNeeded(force: true) { added in
            newData = newData || added
            group.leave()
        }
        group.enter()
        BackgroundRefreshService.shared.refresh { refreshed in
            newData = newData || refreshed
            group.leave()
        }
        group.notify(queue: .main) {
            AppLog.notifications("background fetch finished: newData=\(newData)")
            completion()
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the banner even while the app is in the foreground: an inbox
    /// entry can land during a background fetch that iOS runs with the app
    /// still on screen, and a silently-updated bell reads as "nothing
    /// happened".
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AppLog.notifications("presenting banner in the foreground")
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.alert])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            if let presenter = self?.topPresentableViewController() {
                NotificationsViewController.present(from: presenter)
            }
            completionHandler()
        }
    }

    private func topPresentableViewController() -> UIViewController? {
        guard let root = window?.rootViewController,
              !(root is AuthViewController),
              !(root is SplashViewController)
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
