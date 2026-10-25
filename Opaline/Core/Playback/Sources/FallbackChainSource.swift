import Foundation

/// Tries advertised quality tiers across enabled sources before stepping down.
/// Native delivery breaks quality ties, followed by the user's source order.
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
    private var candidateIndex = 0
    /// The step answering playback and quality questions right now.
    private(set) var active: VideoSource?

    var hasNextCandidate: Bool { candidateIndex + 1 < candidates.count }
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
        let requestGeneration = generation
        // Audio-only retains its existing source/track policy.
        guard !AudioOnlyMode.isEnabled else {
            candidates = steps.enumerated().map {
                PlaybackCandidate(
                    stepIndex: $0.offset, quality: nil, delivery: $0.element.deliveryPreference
                )
            }
            attemptCandidate(
                at: 0, videoId: videoId, cancellation: cancellation, completion: completion
            )
            return
        }
        discover(videoId: videoId, cancellation: cancellation) { [weak self] plan in
            guard let self, self.generation == requestGeneration else {
                return
            }
            self.candidates = plan
            self.attemptCandidate(
                at: 0, videoId: videoId, cancellation: cancellation, completion: completion
            )
        }
    }

    /// Continues the ranked attempts after a mid-playback failure.
    func advance(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        active?.releaseResources()
        attemptCandidate(
            at: candidateIndex + 1,
            videoId: videoId,
            cancellation: cancellation,
            completion: completion
        )
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

// MARK: - Quality-first discovery and attempts

private extension FallbackChainSource {
    /// Probes metadata only; failed/slow probes remain last-resort candidates.
    /// All callbacks enter main before touching discovery or chain state.
    func discover(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping ([PlaybackCandidate]) -> Void
    ) {
        let requestGeneration = generation
        let cap = VideoQualityStore.maxHeight ?? Int.max
        var ladders: [Int: [VideoQuality]] = [:]
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard let self, !finished, self.generation == requestGeneration,
                  cancellation?.isCancelled != true else {
                return
            }
            finished = true
            completion(self.rankedCandidates(ladders: ladders, cap: cap))
        }
        guard !steps.isEmpty else {
            finish()
            return
        }
        for (index, step) in steps.enumerated() {
            source(for: step).probeQualities(videoId: videoId) { [weak self] qualities in
                DispatchQueue.main.async {
                    guard let self, !finished, self.generation == requestGeneration,
                          cancellation?.isCancelled != true else {
                        return
                    }
                    let known = self.source(for: step).availableQualities
                    ladders[index] = qualities.isEmpty ? known : qualities
                    if ladders.count == self.steps.count { finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + probeTimeout, execute: finish)
    }

    func rankedCandidates(ladders: [Int: [VideoQuality]], cap: Int) -> [PlaybackCandidate] {
        let plan = steps.enumerated().flatMap { index, step -> [PlaybackCandidate] in
            let qualities = (ladders[index] ?? []).filter { ($0.height ?? 0) > 0 }
            if qualities.isEmpty {
                return [
                    PlaybackCandidate(
                        stepIndex: index, quality: nil, delivery: step.deliveryPreference
                    )
                ]
            }
            return qualities.map {
                PlaybackCandidate(stepIndex: index, quality: $0, delivery: step.deliveryPreference)
            }
        }
        return PlaybackCandidate.ranked(plan, maximumHeight: cap)
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
        guard index < candidates.count else {
            completion(.failure(Self.exhaustedError))
            return
        }
        let candidate = candidates[index]
        let step = steps[candidate.stepIndex]
        generation += 1
        let requestGeneration = generation
        candidateIndex = index
        active = source(for: step)
        let tier = candidate.quality?.label ?? "unknown quality"
        AppLog.player("chain: trying \(step.id) at \(tier)")
        let finished: (Result<PreparedPlayback, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration,
                      cancellation?.isCancelled != true else {
                    return
                }
                self.candidateFinished(
                    result,
                    videoId: videoId,
                    cancellation: cancellation,
                    completion: completion
                )
            }
        }
        load(candidate, videoId: videoId, cancellation: cancellation, completion: finished)
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

    func candidateFinished(
        _ result: Result<PreparedPlayback, Error>,
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard case .failure(let error) = result else {
            completion(result)
            return
        }
        AppLog.player("chain: \(name) failed (\(error.localizedDescription))")
        active?.releaseResources()
        attemptCandidate(
            at: candidateIndex + 1,
            videoId: videoId,
            cancellation: cancellation,
            completion: completion
        )
    }
}
