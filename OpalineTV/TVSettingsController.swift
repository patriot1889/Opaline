import UIKit

final class TVSettingsController: TVMenuController {
    init() { super.init(title: "settings.title".localized) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }

    private func reload() {
        rows = [
            TVMenuRow(OAuthClient.shared.isSignedIn ? "TV.signOut".localized : "account.signIn".localized) { [weak self] in self?.account() },
            TVMenuRow("TV.language".localized, detail: AppLanguage.effective.displayName) { [weak self] in self?.languages() },
            TVMenuRow("TV.region".localized, detail: DefaultLocalePreferences().gl) { [weak self] in
                self?.edit("TV.region".localized, value: DefaultLocalePreferences().gl) { region in
                    let normalized = region.uppercased()
                    guard normalized.count == 2, Locale.isoRegionCodes.contains(normalized), normalized != "CN" else { return false }
                    UserDefaults.standard.set(normalized, forKey: UserDefaultsKeys.Localization.region)
                    return true
                }
            },
            TVMenuRow("TV.appearance".localized) { [weak self] in
                self?.choose("TV.appearance".localized, values: ["TV.system".localized, "TV.dark".localized, "TV.light".localized]) { index in
                    UserDefaults.standard.set(["system", "dark", "light"][index], forKey: "TV.appearance")
                    (UIApplication.shared.delegate as? TVAppDelegate)?.applyAppearance()
                }
            },
            toggle("TV.autoplay".localized, enabled: AutoplayPreference.isEnabled) { AutoplayPreference.isEnabled = $0 },
            toggle("TV.playlistAutoplay".localized, enabled: AutoplayPreference.isMixEnabled) { AutoplayPreference.isMixEnabled = $0 },
            TVMenuRow("player.menu.quality".localized, detail: VideoQualityStore.displayName(VideoQualityStore.wifi)) { [weak self] in
                self?.choose("player.menu.quality".localized, values: VideoQualityStore.options.map(VideoQualityStore.displayName)) {
                    VideoQualityStore.wifi = VideoQualityStore.options[$0]
                }
            },
            toggle("TV.autoDub".localized, enabled: AutoDubPreference.isEnabled) { AutoDubPreference.isEnabled = $0 },
            TVMenuRow("TV.audioLanguage".localized, detail: AutoDubPreference.languageOverride ?? "TV.system".localized) { [weak self] in
                self?.chooseLanguage("TV.audioLanguage".localized) { AutoDubPreference.languageOverride = $0 }
            },
            toggle("TV.ignoreAIDubs".localized, enabled: AutoDubPreference.ignoreAIDubs) { AutoDubPreference.ignoreAIDubs = $0 },
            TVMenuRow("player.menu.subtitles".localized, detail: UserDefaults.standard.string(forKey: "TV.captions") ?? "player.subtitles.off".localized) { [weak self] in
                self?.chooseLanguage("player.menu.subtitles".localized, defaultTitle: "player.subtitles.off".localized) {
                    UserDefaults.standard.set($0, forKey: "TV.captions")
                }
            },
            toggle("SponsorBlock", enabled: SponsorBlockService.enabled) { SponsorBlockService.enabled = $0 },
            TVMenuRow("TV.sponsorCategories".localized) { [weak self] in self?.sponsorCategories() },
            TVMenuRow("TV.solverServer".localized, detail: AppURLs.SolverServer.baseURL) { [weak self] in
                self?.edit("TV.solverServer".localized, value: AppURLs.SolverServer.baseURL) { value in
                    guard value.isEmpty || (URL(string: value)?.host != nil && ["https", "http"].contains(URL(string: value)?.scheme ?? "")) else { return false }
                    UserDefaults.standard.set(value, forKey: UserDefaultsKeys.Debug.serverBaseURL)
                    return true
                }
            }
        ]
        if isViewLoaded { tableView.reloadData() }
    }
    private func toggle(_ title: String, enabled: Bool, set: @escaping (Bool) -> Void) -> TVMenuRow {
        TVMenuRow(title, detail: enabled ? "TV.on".localized : "TV.off".localized) { [weak self] in
            set(!enabled)
            self?.reload()
        }
    }
    private func account() {
        if OAuthClient.shared.isSignedIn {
            let alert = UIAlertController(title: "TV.signOut".localized, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "TV.signOut".localized, style: .destructive) { [weak self] _ in
                OAuthClient.shared.signOut()
                OAuthClient.shared.isAnonymous = true
                WatchProgressStore.shared.clearAll()
                PlaybackQueue.shared.clear()
                SearchHistoryStore.shared.clear()
                AppCache.shared.clearAllDiskCache()
                UserProfileStore.shared.clear()
                UserDefaults.standard.removeObject(forKey: "WatchProgressSync.lastSync")
                self?.reload()
                (UIApplication.shared.delegate as? TVAppDelegate)?.showMain()
            })
            alert.addAction(UIAlertAction(title: "TV.cancel".localized, style: .cancel))
            present(alert, animated: true)
        } else {
            let auth = TVAuthController()
            auth.onComplete = { [weak self, weak auth] in
                auth?.dismiss(animated: true) {
                    self?.reload()
                    (UIApplication.shared.delegate as? TVAppDelegate)?.showMain()
                }
            }
            present(auth, animated: true)
        }
    }
    private func languages() {
        chooseLanguage("TV.language".localized) { code in
            AppLanguage.override = code.flatMap(AppLanguage.init(rawValue:))
            (UIApplication.shared.delegate as? TVAppDelegate)?.showMain()
        }
    }
    private func chooseLanguage(_ title: String, defaultTitle: String = "TV.system".localized,
                                set: @escaping (String?) -> Void) {
        choose(title, values: [defaultTitle] + AppLanguage.allCases.map(\.displayName)) { index in
            set(index == 0 ? nil : AppLanguage.allCases[index - 1].rawValue)
        }
    }
    private func sponsorCategories() {
        let screen = TVMenuController(title: "SponsorBlock")
        screen.rows = SBCategory.allCases.map { category in
            TVMenuRow(category.displayName, detail: SponsorBlockService.skipBehavior(for: category).displayName) { [weak self] in
                let options = SBSkipBehavior.options(for: category)
                self?.choose(category.displayName, values: options.map(\.displayName)) { index in
                    SponsorBlockService.setSkipBehavior(options[index], for: category)
                }
            }
        }
        navigationController?.pushViewController(screen, animated: true)
    }
    private func choose(_ title: String, values: [String], selected: @escaping (Int) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (index, value) in values.enumerated() {
            alert.addAction(UIAlertAction(title: value, style: .default) { [weak self] _ in selected(index); self?.reload() })
        }
        alert.addAction(UIAlertAction(title: "TV.cancel".localized, style: .cancel))
        // Category actions can be invoked while a pushed menu is visible.
        (navigationController?.topViewController ?? self).present(alert, animated: true)
    }
    private func edit(_ title: String, value: String, save: @escaping (String) -> Bool) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = value; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "TV.save".localized, style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if save(text) { self?.reload() }
            else { self?.edit(title, value: text, save: save) }
        })
        alert.addAction(UIAlertAction(title: "TV.cancel".localized, style: .cancel))
        present(alert, animated: true)
    }
}
