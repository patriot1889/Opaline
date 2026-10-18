import UIKit

@main
final class TVAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let dependencies = ServiceDependencies.live()
    private var authObserver: NSObjectProtocol?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Hosted unit tests exercise shared services without starting live requests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            window = UIWindow(frame: UIScreen.main.bounds)
            window?.rootViewController = UIViewController()
            window?.makeKeyAndVisible()
            return true
        }
        AppLog.banner()
        ChannelInfoStore.shared.configure(channelService: dependencies.channelService)
        UserProfileStore.shared.configure(accountService: dependencies.accountService)
        window = UIWindow(frame: UIScreen.main.bounds)
        if OAuthClient.shared.isSignedIn || OAuthClient.shared.isAnonymous {
            showMain()
        } else {
            let auth = TVAuthController()
            auth.onComplete = { [weak self] in self?.showMain() }
            window?.rootViewController = auth
            applyAppearance()
        }
        window?.makeKeyAndVisible()
        authObserver = NotificationCenter.default.addObserver(
            forName: .authorizationRequired, object: nil, queue: .main
        ) { [weak self] _ in self?.presentSignIn() }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        OAuthClient.shared.refreshIfStale()
        WatchProgressSyncService.shared.syncIfNeeded()
    }

    func showMain() {
        window?.rootViewController = TVRootController(dependencies: dependencies)
        applyAppearance()
        WatchProgressSyncService.shared.syncIfNeeded()
    }

    func applyAppearance() {
        let raw = UserDefaults.standard.string(forKey: "TV.appearance") ?? "system"
        window?.overrideUserInterfaceStyle = raw == "dark" ? .dark : raw == "light" ? .light : .unspecified
    }

    func presentSignIn() {
        guard let root = window?.rootViewController, root.presentedViewController == nil else { return }
        let auth = TVAuthController()
        auth.onComplete = { [weak self, weak auth] in
            auth?.dismiss(animated: true) { self?.showMain() }
        }
        root.present(auth, animated: true)
    }
}

final class TVRootController: UITabBarController {
    init(dependencies: ServiceDependencies) {
        super.init(nibName: nil, bundle: nil)
        let router = TVRouter(dependencies: dependencies)
        let home = router.feed(.home)
        let subscriptions = router.feed(.subscriptions)
        let search = TVSearchController(router: router)
        let library = TVMenuController(title: "library.title".localized)
        library.rows = [
            TVMenuRow("library.history".localized) { [weak library] in
                library?.navigationController?.pushViewController(router.feed(.history), animated: true)
            },
            TVMenuRow("library.playlists".localized) { [weak library] in
                library?.navigationController?.pushViewController(router.playlists(), animated: true)
            }
        ]
        let settings = TVSettingsController()
        let screens: [(UIViewController, String, String)] = [
            (home, "home.title".localized, "house"), (search, "search.title".localized, "magnifyingglass"),
            (subscriptions, "subscriptions.title".localized, "play.rectangle.on.rectangle"),
            (library, "library.title".localized, "rectangle.stack"), (settings, "settings.title".localized, "gearshape")
        ]
        viewControllers = screens.map { screen, name, symbol in
            // The tab menu already identifies these top-level screens.
            screen.navigationItem.title = ""
            let navigation = UINavigationController(rootViewController: screen)
            navigation.tabBarItem = UITabBarItem(title: name, image: UIImage(systemName: symbol), tag: 0)
            return navigation
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct TVMenuRow {
    let title: String
    var detail: String?
    let action: () -> Void
    init(_ title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.action = action
    }
}

class TVMenuController: UITableViewController {
    var rows: [TVMenuRow] = []
    init(title: String) {
        super.init(style: .plain)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.rowHeight = 100
        tableView.remembersLastFocusedIndexPath = true
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Root titles already live in the tab menu. A blank navigation bar
        // still draws a shaded overlay that can cover the focused table row.
        navigationController?.setNavigationBarHidden(navigationController?.viewControllers.first === self, animated: animated)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = rows[indexPath.row].title
        content.secondaryText = rows[indexPath.row].detail
        content.prefersSideBySideTextAndSecondaryText = true
        content.textProperties.font = .systemFont(ofSize: 30)
        content.secondaryTextProperties.font = .systemFont(ofSize: 25)
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        rows[indexPath.row].action()
    }
}

enum TVPalette {
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .light ? UIColor(white: 0.96, alpha: 1) : UIColor(white: 0.05, alpha: 1)
    }
}
