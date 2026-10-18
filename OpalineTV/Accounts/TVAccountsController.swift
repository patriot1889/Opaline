import UIKit

enum TVAccountText {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "TVAccounts")
    }
}

final class TVAccountsController: TVMenuController {
    init() { super.init(title: TVAccountText.string("Accounts")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        let store = TVAccountStore.shared
        rows = store.accounts.map { account in
            TVMenuRow(account.name, detail: account.id == store.activeAccount?.id ? TVAccountText.string("Active") : nil) { [weak self] in
                self?.options(account)
            }
        }
        rows.append(TVMenuRow(TVAccountText.string("Add account")) { [weak self] in self?.addAccount() })
        rows.append(TVMenuRow(TVAccountText.string("Guest"), detail: store.activeAccount == nil ? TVAccountText.string("Active") : nil) { [weak self] in
            self?.change { try store.select(nil) }
        })
        if isViewLoaded { tableView.reloadData() }
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
