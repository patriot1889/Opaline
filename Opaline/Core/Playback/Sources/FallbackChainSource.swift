import Foundation

/// Checks sources in saved order and stops when one serves the selected resolution.
/// Lower tiers are retained for ranked fallback after every source falls short.
final class FallbackChainSource: VideoSource {
    private static let exhaustedError = NSError(
        domain: "FallbackChainSource",
        code: 0,
        userInfo: [NSLocalizedDescriptionKey: "No playback source could serve this video"]
    )

    private let steps: [PlaybackStep]
    private let apiClient: WatchService
    private let probeTimeout: TimeInterval
    private var built: [String: VideoSource] = [:]
    private var generation = 0
    private var candidates: [PlaybackCandidate] = []
    private var nextStepIndex = 0
    private var maximumHeight = 1_080
    private var audioOnly = false
    /// The step answering playback and quality questions right now.
    private(set) var active: VideoSource?

    var hasNextCandidate: Bool { nextStepIndex < steps.count || !candidates.isEmpty }
    var prioritizesVideoQuality: Bool { true }
    var name: String { active?.name ?? steps.first?.id ?? "chain" }
    var listsAudioTracks: Bool { dubCapableSource() != nil }
    var supportsQualitySelection: Bool { active?.supportsQualitySelection ?? false }
    var availableQualities: [VideoQuality] { active?.availableQualities ?? [] }
    var currentQuality: VideoQuality? { active?.currentQuality }
    var currentCodecs: String? { active?.currentCodecs }
    var availableAudioTracks: [AudioTrack] { active?.availableAudioTracks ?? [] }
    var currentAudioTrack: AudioTrack? { active?.currentAudioTrack }

    init(steps: [PlaybackStep], apiClient: WatchService, probeTimeout: TimeInterval = 10) {
        self.steps = steps
        self.apiClient = apiClient
        self.probeTimeout = probeTimeout
    }

    func loadPlayback(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        releaseResources()
        maximumHeight = VideoQualityStore.maxHeight ?? Int.max
        audioOnly = AudioOnlyMode.isEnabled
        if audioOnly {
            nextStepIndex = steps.count
            candidates = steps.enumerated().map {
                PlaybackCandidate(
                    stepIndex: $0.offset, quality: nil, delivery: $0.element.deliveryPreference
                )
            }
        }
        continueSelection(videoId: videoId, cancellation: cancellation, completion: completion)
    }

    /// Tries unvisited sources before lowering resolution during recovery.
    func advance(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        generation += 1
        active?.releaseResources()
        active = nil
        continueSelection(videoId: videoId, cancellation: cancellation, completion: completion)
    }

    func selectQuality(
        _ quality: VideoQuality,
        resumeAt: Double?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard let active else {
            completion(.failure(Self.exhaustedError))
            return
        }
        active.selectQuality(quality, resumeAt: resumeAt, completion: completion)
    }

    func selectAudioTrack(
        _ track: AudioTrack,
        resumeAt: Double?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard let active else {
            completion(.failure(Self.exhaustedError))
            return
        }
        active.selectAudioTrack(track, resumeAt: resumeAt, completion: completion)
    }

    func probeAudioTracks(
        videoId: String,
        completion: @escaping ([AudioTrack]) -> Void
    ) {
        guard let source = dubCapableSource() else {
            completion([])
            return
        }
        source.probeAudioTracks(videoId: videoId, completion: completion)
    }

    func probeQualities(
        videoId: String,
        completion: @escaping ([VideoQuality]) -> Void
    ) {
        guard let step = steps.first else {
            completion([])
            return
        }
        source(for: step).probeQualities(videoId: videoId, completion: completion)
    }

    func releaseResources() {
        generation += 1
        candidates = []
        nextStepIndex = 0
        built.values.forEach { $0.releaseResources() }
        built.removeAll()
        active = nil
    }

    /// The first step in the chain that can list dubs. Asked by capability,
    /// not by sign-in: visionOS lists and plays them anonymously, so an
    /// account is no longer what dubbed audio depends on.
    func dubCapableSource() -> VideoSource? {
        for step in steps {
            let candidate = source(for: step)
            if candidate.listsAudioTracks {
                return candidate
            }
        }
        return nil
    }

    private func source(for step: PlaybackStep) -> VideoSource {
        if let existing = built[step.id] {
            return existing
        }
        let source = step.make(apiClient)
        built[step.id] = source
        return source
    }
}

// MARK: - Sequential discovery and quality fallback

private extension FallbackChainSource {
    func continueSelection(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else {
            return
        }
        // The current source's requested tiers come before probing another source.
        // Lower tiers wait until every eligible source has had a chance at the target.
        if let index = candidates.firstIndex(where: {
            audioOnly || meetsTarget($0.quality)
        }) {
            attemptCandidate(
                at: index, videoId: videoId, cancellation: cancellation, completion: completion
            )
        } else if nextStepIndex < steps.count {
            discoverNext(videoId: videoId, cancellation: cancellation, completion: completion)
        } else if !candidates.isEmpty {
            attemptCandidate(
                at: 0, videoId: videoId, cancellation: cancellation, completion: completion
            )
        } else {
            completion(.failure(Self.exhaustedError))
        }
    }

    func meetsTarget(_ quality: VideoQuality?) -> Bool {
        guard let quality else {
            return false
        }
        // Wide-aspect videos can advertise the 1080p tier with only 1012 coded lines.
        return quality.height == maximumHeight || quality.label.hasPrefix("\(maximumHeight)p")
    }

    /// One bounded metadata probe at a time; late callbacks cannot start another attempt.
    func discoverNext(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let index = nextStepIndex
        nextStepIndex += 1
        let step = steps[index]
        let source = source(for: step)
        generation += 1
        let requestGeneration = generation
        var finished = false
        AppLog.player("chain: checking \(step.id) for \(maximumHeight)p")
        let finish: ([VideoQuality]) -> Void = { [weak self, weak source] qualities in
            guard let self, !finished, self.generation == requestGeneration,
                  cancellation?.isCancelled != true else {
                return
            }
            finished = true
            self.retainQualities(
                qualities.isEmpty ? source?.availableQualities ?? [] : qualities, at: index
            )
            self.continueSelection(
                videoId: videoId, cancellation: cancellation, completion: completion
            )
        }
        source.probeQualities(videoId: videoId) { qualities in
            DispatchQueue.main.async { finish(qualities) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + probeTimeout) { finish([]) }
    }

    func retainQualities(_ qualities: [VideoQuality], at index: Int) {
        let ladder = qualities.filter { ($0.height ?? 0) > 0 }
        let step = steps[index]
        let discovered: [PlaybackCandidate]
        if ladder.isEmpty {
            discovered = [
                PlaybackCandidate(
                    stepIndex: index, quality: nil, delivery: step.deliveryPreference
                )
            ]
        } else {
            discovered = ladder.map {
                PlaybackCandidate(stepIndex: index, quality: $0, delivery: step.deliveryPreference)
            }
        }
        candidates = PlaybackCandidate.ranked(
            candidates + discovered, maximumHeight: maximumHeight
        )
    }

    func attemptCandidate(
        at index: Int,
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else {
            return
        }
        let candidate = candidates.remove(at: index)
        let step = steps[candidate.stepIndex]
        generation += 1
        let requestGeneration = generation
        active = source(for: step)
        let tier = candidate.quality?.label ?? "unknown quality"
        AppLog.player("chain: trying \(step.id) at \(tier)")
        load(candidate, videoId: videoId, cancellation: cancellation) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration,
                      cancellation?.isCancelled != true else {
                    return
                }
                switch result {
                case .success:
                    completion(result)
                case .failure(let error):
                    AppLog.player("chain: \(self.name) failed (\(error.localizedDescription))")
                    self.active?.releaseResources()
                    self.active = nil
                    self.continueSelection(
                        videoId: videoId, cancellation: cancellation, completion: completion
                    )
                }
            }
        }
    }

    func load(
        _ candidate: PlaybackCandidate,
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let source = source(for: steps[candidate.stepIndex])
        if let quality = candidate.quality {
            source.loadPlayback(
                videoId: videoId,
                quality: quality,
                cancellation: cancellation,
                completion: completion
            )
        } else {
            source.loadPlayback(
                videoId: videoId, cancellation: cancellation, completion: completion
            )
        }
    }
}
