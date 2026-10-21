import UIKit

enum TVAccountText {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "TVAccounts")
    }
}

final class TVAccountsController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let choosingAccount: Bool
    private let layout = UICollectionViewFlowLayout()
    private lazy var profiles = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let manage = UIButton(type: .system)
    private let guest = UIButton(type: .system)
    private var manageCenterX: NSLayoutConstraint!
    private var accounts: [TVAccountStore.Account] = []
    private var focusedAccountID: String?

    init(choosingAccount: Bool = false) {
        self.choosingAccount = choosingAccount
        super.init(nibName: nil, bundle: nil)
        title = TVAccountText.string(choosingAccount ? "Who's watching?" : "Accounts")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        let backdrop = TVAccountBackdropView()
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        let heading = UILabel()
        heading.text = title
        heading.font = .systemFont(ofSize: 26, weight: .medium)
        heading.textColor = UIColor.white.withAlphaComponent(0.7)
        heading.textAlignment = .center
        heading.accessibilityTraits = .header

        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 40
        profiles.backgroundColor = .clear
        profiles.contentInsetAdjustmentBehavior = .never
        profiles.clipsToBounds = false
        profiles.showsHorizontalScrollIndicator = false
        profiles.remembersLastFocusedIndexPath = true
        profiles.dataSource = self
        profiles.delegate = self
        profiles.register(TVAccountProfileCell.self, forCellWithReuseIdentifier: "profile")
        profiles.accessibilityIdentifier = "TV.accountProfiles"

        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(white: 1, alpha: 0.13)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 34, bottom: 18, trailing: 34)
        configuration.title = TVAccountText.string("Watch as guest")
        guest.configuration = configuration
        guest.accessibilityIdentifier = "TV.watchAsGuest"
        guest.addAction(UIAction { [weak self] _ in
            self?.change { try TVAccountStore.shared.select(nil) }
        }, for: .primaryActionTriggered)
        configuration.title = nil
        configuration.image = UIImage(systemName: "gearshape")
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        manage.configuration = configuration
        manage.accessibilityIdentifier = "TV.manageAccount"
        manage.addAction(UIAction { [weak self] _ in
            guard let self, let account = self.accounts.first(where: { $0.id == self.focusedAccountID }) else { return }
            self.options(account)
        }, for: .primaryActionTriggered)

        for child in [heading, profiles, manage, guest] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        manageCenterX = manage.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        NSLayoutConstraint.activate([
            heading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 184),
            profiles.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            profiles.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            profiles.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            profiles.heightAnchor.constraint(equalToConstant: 390),
            manage.topAnchor.constraint(equalTo: profiles.bottomAnchor, constant: 24),
            manageCenterX,
            manage.widthAnchor.constraint(equalToConstant: 68),
            manage.heightAnchor.constraint(equalToConstant: 68),
            guest.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guest.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reload()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [profiles] }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let totalWidth = CGFloat(accounts.count + 1) * 300 + CGFloat(accounts.count) * 40
        let inset = max(90, (profiles.bounds.width - totalWidth) / 2)
        let next = UIEdgeInsets(top: 16, left: inset, bottom: 16, right: inset)
        if layout.sectionInset != next { layout.sectionInset = next }
        updateManagePosition()
    }

    private func reload() {
        accounts = TVAccountStore.shared.accounts
        if !accounts.contains(where: { $0.id == focusedAccountID }) {
            focusedAccountID = TVAccountStore.shared.activeAccount?.id ?? accounts.first?.id
        }
        updateManageButton()
        profiles.reloadData()
        view.setNeedsLayout()
    }

    private func updateManageButton() {
        manage.isHidden = focusedAccountID == nil
        let name = accounts.first { $0.id == focusedAccountID }?.name ?? ""
        manage.accessibilityLabel = TVAccountText.string("Manage account") + ": " + name
        updateManagePosition()
    }

    private func updateManagePosition() {
        guard let index = accounts.firstIndex(where: { $0.id == focusedAccountID }),
              let attributes = profiles.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        else { return }
        // Convert from scrolling content coordinates so Down stays aligned with this profile,
        // including while the collection view scrolls to reveal accounts at either end.
        let center = profiles.convert(attributes.center, to: view)
        manageCenterX.constant = center.x - view.bounds.midX
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateManagePosition()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        accounts.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "profile", for: indexPath) as! TVAccountProfileCell
        if indexPath.item < accounts.count {
            let account = accounts[indexPath.item]
            cell.configure(name: account.name, index: indexPath.item,
                           active: account.id == TVAccountStore.shared.activeAccount?.id)
        } else {
            cell.configure(name: TVAccountText.string("Add account"), index: nil, active: false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize { CGSize(width: 300, height: 350) }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        IndexPath(item: accounts.firstIndex { $0.id == focusedAccountID } ?? 0, section: 0)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let index = context.nextFocusedIndexPath?.item else { return }
        // Retain the profile while navigating down to its management action.
        focusedAccountID = index < accounts.count ? accounts[index].id : nil
        updateManageButton()
        coordinator.addCoordinatedAnimations {
            self.view.layoutIfNeeded()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < accounts.count else { addAccount(); return }
        let account = accounts[indexPath.item]
        if choosingAccount {
            change { try TVAccountStore.shared.select(account.id) }
        } else { options(account) }
    }

    private func options(_ account: TVAccountStore.Account) {
        let alert = UIAlertController(title: account.name, message: nil, preferredStyle: .actionSheet)
        if account.id != TVAccountStore.shared.activeAccount?.id || !OAuthClient.shared.isSignedIn {
            alert.addAction(UIAlertAction(title: TVAccountText.string("Switch to account"), style: .default) { [weak self] _ in
                self?.change { try TVAccountStore.shared.select(account.id) }
            })
        }
        alert.addAction(UIAlertAction(title: TVAccountText.string("Rename account"), style: .default) { [weak self] _ in
            self?.rename(account)
        })
        alert.addAction(UIAlertAction(title: TVAccountText.string("Remove account"), style: .destructive) { [weak self] _ in
            self?.confirmRemoval(account)
        })
        alert.addAction(UIAlertAction(title: "TV.cancel".tvLocalized, style: .cancel))
        present(alert, animated: true)
    }

    private func addAccount() {
        let auth = TVAuthController()
        auth.onComplete = { [weak auth] in
            auth?.dismiss(animated: true) { (UIApplication.shared.delegate as? TVAppDelegate)?.showMain() }
        }
        present(auth, animated: true)
    }

    private func rename(_ account: TVAccountStore.Account) {
        let alert = UIAlertController(title: TVAccountText.string("Rename account"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = account.name }
        alert.addAction(UIAlertAction(title: "TV.save".tvLocalized, style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            do { try TVAccountStore.shared.rename(account.id, to: name); self?.reload() }
            catch { self?.showError(error) }
        })
        alert.addAction(UIAlertAction(title: "TV.cancel".tvLocalized, style: .cancel))
        present(alert, animated: true)
    }

    private func confirmRemoval(_ account: TVAccountStore.Account) {
        let alert = UIAlertController(title: TVAccountText.string("Remove account"), message: account.name, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: TVAccountText.string("Remove account"), style: .destructive) { [weak self] _ in
            do {
                if account.id == TVAccountStore.shared.activeAccount?.id {
                    try TVAccountSession.change { try TVAccountStore.shared.remove(account.id) }
                    (UIApplication.shared.delegate as? TVAppDelegate)?.showMain()
                } else {
                    try TVAccountStore.shared.remove(account.id)
                    self?.reload()
                }
                let defaults = UserDefaults.standard
                for suffix in ["searchHistory", "fractions", "localTimes"] {
                    defaults.removeObject(forKey: "TV.accounts.\(account.id).\(suffix)")
                }
            } catch { self?.showError(error) }
        })
        alert.addAction(UIAlertAction(title: "TV.cancel".tvLocalized, style: .cancel))
        present(alert, animated: true)
    }

    private func change(_ mutation: () throws -> Void) {
        do {
            try TVAccountSession.change(mutation)
            (UIApplication.shared.delegate as? TVAppDelegate)?.showMain()
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: TVAccountText.string("Accounts"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "TV.cancel".tvLocalized, style: .cancel))
        present(alert, animated: true)
    }

    static func loadActiveName() {
        guard let id = TVAccountStore.shared.activeAccount?.id else { return }
        let generation = TVSessionFence.generation
        ServiceContainer.account.fetchAccountInfo { result in
            DispatchQueue.main.async {
                guard generation == TVSessionFence.generation, case .success(let info) = result else { return }
                do { try TVAccountStore.shared.rename(id, to: info.name) }
                catch { AppLog.auth("Unable to save TV account name") }
            }
        }
    }
}

/// A circular profile keeps the focus treatment on the avatar instead of a rectangular card.
private final class TVAccountProfileCell: UICollectionViewCell {
    private let avatar = UIView()
    private let initial = UILabel()
    private let name = UILabel()
    private let caption = UILabel()
    private let ring = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.clipsToBounds = false
        avatar.layer.cornerRadius = 130
        ring.layer.cornerRadius = 140
        ring.layer.borderWidth = 5
        ring.layer.borderColor = UIColor.white.cgColor
        ring.alpha = 0
        initial.textAlignment = .center
        initial.font = .systemFont(ofSize: 112, weight: .regular)
        initial.textColor = .white
        name.font = .systemFont(ofSize: 28, weight: .semibold)
        name.textAlignment = .center
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        caption.font = .systemFont(ofSize: 22)
        caption.textColor = UIColor.white.withAlphaComponent(0.65)
        caption.textAlignment = .center
        for child in [avatar, ring, name, caption] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        initial.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(initial)
        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 260), avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor),
            ring.centerXAnchor.constraint(equalTo: avatar.centerXAnchor), ring.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 280), ring.heightAnchor.constraint(equalTo: ring.widthAnchor),
            initial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor), initial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            name.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 28),
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), name.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            caption.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            caption.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name text: String, index: Int?, active: Bool) {
        name.text = text
        caption.text = active ? TVAccountText.string("Active") : nil
        initial.text = index == nil ? "+" : String(text.prefix(1)).uppercased()
        let colors: [UIColor] = [UIColor(red: 0.22, green: 0.48, blue: 0.65, alpha: 1),
                                 UIColor(red: 0.86, green: 0.30, blue: 0.16, alpha: 1),
                                 UIColor(red: 0.40, green: 0.30, blue: 0.65, alpha: 1),
                                 UIColor(red: 0.19, green: 0.54, blue: 0.43, alpha: 1)]
        avatar.backgroundColor = index.map { colors[$0 % colors.count] } ?? UIColor(red: 0.24, green: 0.23, blue: 0.36, alpha: 1)
        accessibilityLabel = text
        accessibilityValue = caption.text
        accessibilityIdentifier = index.map { "TV.account.\($0)" } ?? "TV.addAccount"
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.ring.alpha = self.isFocused ? 1 : 0
            let scale: CGFloat = self.isFocused && !UIAccessibility.isReduceMotionEnabled ? 1.07 : 1
            self.avatar.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.ring.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }
}

/// tvOS-owned artwork, shared by the chooser and the device-code sign-in screen.
final class TVAccountBackdropView: UIView {
    private let base = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let petals = (0..<3).map { _ in CAGradientLayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        base.colors = [UIColor(red: 0.055, green: 0.075, blue: 0.14, alpha: 1).cgColor,
                       UIColor(red: 0.10, green: 0.065, blue: 0.17, alpha: 1).cgColor]
        base.startPoint = .zero
        base.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(base)
        glow.type = .radial
        glow.colors = [UIColor(red: 0.45, green: 0.16, blue: 0.47, alpha: 0.55).cgColor, UIColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0.95, y: 1)
        glow.endPoint = CGPoint(x: 0.3, y: 0.2)
        layer.addSublayer(glow)
        for petal in petals {
            petal.colors = [UIColor(red: 0.57, green: 0.39, blue: 0.86, alpha: 1).cgColor,
                            UIColor(red: 0.80, green: 0.24, blue: 0.52, alpha: 1).cgColor]
            petal.startPoint = .zero
            petal.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(petal)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        glow.frame = bounds
        let w = bounds.width, h = bounds.height
        let frames = [CGRect(x: w * 0.79, y: h * 0.76, width: w * 0.18, height: h * 0.55),
                      CGRect(x: w * 0.91, y: h * 0.81, width: w * 0.17, height: h * 0.50),
                      CGRect(x: w * 0.65, y: h * 0.93, width: w * 0.42, height: h * 0.26)]
        for (petal, frame) in zip(petals, frames) {
            petal.frame = frame
            let mask = CAShapeLayer()
            mask.path = UIBezierPath(ovalIn: petal.bounds).cgPath
            petal.mask = mask
        }
        CATransaction.commit()
    }
}
