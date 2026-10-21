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
        if TVAccountStore.shared.accounts.count > 1 {
            let accounts = TVAccountsController(choosingAccount: true)
            window?.rootViewController = UINavigationController(rootViewController: accounts)
            applyAppearance()
        } else if OAuthClient.shared.isSignedIn || OAuthClient.shared.isAnonymous {
            showMain()
        } else {
            window?.rootViewController = UINavigationController(rootViewController: TVAccountsController(choosingAccount: true))
            applyAppearance()
        }
        window?.makeKeyAndVisible()
        authObserver = NotificationCenter.default.addObserver(
            forName: .authorizationRequired, object: nil, queue: .main
        ) { [weak self] _ in self?.presentSignIn() }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Wait for the launch account choice before making account-scoped requests.
        guard window?.rootViewController is TVRootController else { return }
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
    private let accountButton = UIButton(type: .system)

    init(dependencies: ServiceDependencies) {
        super.init(nibName: nil, bundle: nil)
        let router = TVRouter(dependencies: dependencies)
        let home = router.feed(.home)
        let subscriptions = router.feed(.subscriptions)
        let search = TVSearchController(router: router)
        let library = router.library()
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

    override func viewDidLoad() {
        super.viewDidLoad()
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "person.crop.circle")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 36)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        accountButton.configuration = configuration
        accountButton.accessibilityLabel = TVAccountText.string("Switch account")
        accountButton.accessibilityValue = TVAccountStore.shared.activeAccount?.name ?? TVAccountText.string("Guest")
        accountButton.accessibilityIdentifier = "TV.switchAccount"
        accountButton.addAction(UIAction { [weak self] _ in
            guard let self, self.presentedViewController == nil else { return }
            let accounts = TVAccountsController(choosingAccount: true)
            self.present(UINavigationController(rootViewController: accounts), animated: true)
        }, for: .primaryActionTriggered)
        accountButton.translatesAutoresizingMaskIntoConstraints = false
        // Keep the button in the tab bar so it follows the bar offscreen while browsing.
        // Accessory views disable interaction, so use the bar itself as the container.
        tabBar.addSubview(accountButton)
        NSLayoutConstraint.activate([
            accountButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            accountButton.leadingAnchor.constraint(equalTo: tabBar.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            accountButton.widthAnchor.constraint(equalToConstant: 72),
            accountButton.heightAnchor.constraint(equalToConstant: 72)
        ])
    }
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
    var showsPageHeadingAtRoot = false
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
        navigationController?.setNavigationBarHidden(true, animated: animated)
        // Keep page titles in a compact row without the system bar's shaded overlay.
        if showsPageHeadingAtRoot || navigationController?.viewControllers.first !== self {
            let heading = UILabel(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 80))
            heading.text = title
            heading.font = .systemFont(ofSize: 32, weight: .semibold)
            heading.textColor = .label
            heading.accessibilityTraits = .header
            tableView.tableHeaderView = heading
        } else {
            tableView.tableHeaderView = nil
        }
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
