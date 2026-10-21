import AVKit

protocol TVDisplayCriteriaDestination: AnyObject {
    var preferredDisplayCriteria: AVDisplayCriteria? { get set }
}

extension AVDisplayManager: TVDisplayCriteriaDestination {}

/// Own display matching for the entire watch session, independently of the video view's size.
/// AVKit's automatic matching releases its criteria when the video leaves full screen.
@MainActor
final class TVPlaybackDisplayMode {
    private let loadCriteria: (AVAsset) async throws -> AVDisplayCriteria
    private var destination: TVDisplayCriteriaDestination?
    private var previousCriteria: AVDisplayCriteria?
    private var videoCriteria: AVDisplayCriteria?
    private var pendingLoad: Task<Void, Never>?
    private var generation = 0

    init(loadCriteria: @escaping (AVAsset) async throws -> AVDisplayCriteria = {
        try await $0.load(.preferredDisplayCriteria)
    }) {
        self.loadCriteria = loadCriteria
    }

    func bind(to destination: TVDisplayCriteriaDestination) {
        guard self.destination !== destination else { return }
        self.destination?.preferredDisplayCriteria = previousCriteria
        self.destination = destination
        previousCriteria = destination.preferredDisplayCriteria
        if let videoCriteria { destination.preferredDisplayCriteria = videoCriteria }
    }

    /// Keep the current mode while another item or quality is being prepared.
    func cancelPendingUpdate() {
        generation += 1
        pendingLoad?.cancel()
        pendingLoad = nil
    }

    @discardableResult
    func update(for asset: AVAsset) -> Task<Void, Never> {
        cancelPendingUpdate()
        let generation = generation
        let loadCriteria = loadCriteria
        let task = Task { @MainActor [weak self] in
            do {
                let criteria = try await loadCriteria(asset)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.videoCriteria = criteria
                self.destination?.preferredDisplayCriteria = criteria
            } catch {
                // Retain the last known mode if this asset cannot provide criteria.
                guard !Task.isCancelled else { return }
                AppLog.player("display criteria unavailable: \(error)")
            }
        }
        pendingLoad = task
        return task
    }

    func restore() {
        cancelPendingUpdate()
        destination?.preferredDisplayCriteria = previousCriteria
        destination = nil
        previousCriteria = nil
        videoCriteria = nil
    }
}
