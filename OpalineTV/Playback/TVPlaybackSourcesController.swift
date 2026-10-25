import UIKit

final class TVPlaybackSourcesController: TVMenuController {
    init() { super.init(title: "TV.playbackSources".tvLocalized) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        let registry = PlaybackStepRegistry.default
        let enabled = PlaybackChainSettings.enabled
        rows = PlaybackChainSettings.order.compactMap { id in
            guard let step = registry.step(id: id) else { return nil }
            var detail = (enabled.contains(id) ? "TV.on" : "TV.off").tvLocalized
            if step.requiresSignIn && !OAuthClient.shared.isSignedIn {
                detail += " · " + "TV.source.signInRequired".tvLocalized
            }
            return TVMenuRow(step.title, detail: detail) { [weak self] in self?.edit(step) }
        }
        if isViewLoaded { tableView.reloadData() }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "TV.sources.explanation".tvLocalized
    }

    private func edit(_ step: PlaybackStep) {
        let alert = UIAlertController(title: step.title, message: nil, preferredStyle: .actionSheet)
        let enabled = PlaybackChainSettings.enabled.contains(step.id)
        alert.addAction(UIAlertAction(title: (enabled ? "TV.source.disable" : "TV.source.enable").tvLocalized,
                                     style: .default) { [weak self] _ in
            var selected = PlaybackChainSettings.enabled
            if enabled { selected.remove(step.id) } else { selected.insert(step.id) }
            PlaybackChainSettings.enabled = selected
            self?.reload()
        })
        let order = PlaybackChainSettings.order
        if let index = order.firstIndex(of: step.id) {
            if index > 0 { addMove(to: alert, id: step.id, offset: -1, title: "TV.source.moveUp") }
            if index + 1 < order.count { addMove(to: alert, id: step.id, offset: 1, title: "TV.source.moveDown") }
        }
        alert.addAction(UIAlertAction(title: "TV.cancel".tvLocalized, style: .cancel))
        present(alert, animated: true)
    }

    private func addMove(to alert: UIAlertController, id: String, offset: Int, title: String) {
        alert.addAction(UIAlertAction(title: title.tvLocalized, style: .default) { [weak self] _ in
            var order = PlaybackChainSettings.order
            guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
            order.swapAt(index, index + offset)
            PlaybackChainSettings.order = order
            self?.reload()
        })
    }
}
