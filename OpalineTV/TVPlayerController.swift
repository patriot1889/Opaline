import AVKit
import UIKit

/// The TV host shares stream preparation with iOS while AVKit owns remote transport input.
final class TVPlayerController: AVPlayerViewController, PlaybackContext {
    var onChannelRequested: ((String, String) -> Void)?
    private let dependencies: ServiceDependencies
    private let queueUsesPlaylistBrowse: Bool
    private var video: Video
    private let facade = PlaybackFacade()
    private let avPlayer = AVPlayer()
    private var cancellation = CancellationToken()
    private var resourceLoader: AVAssetResourceLoaderDelegate?
    private var statusObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var tracksObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var captionTracks: [SubtitleTrack] = []
    private var cues: [SubtitleCue] = []
    private var captionLanguage: String?
    private var subtitleGeneration = 0
    private var segments: [SponsorBlockSegment] = []
    private var skipped = Set<String>()
    private var manualSegment: SponsorBlockSegment?
    private var nextVideo: Video?
    private var lastPosition: Double?
    private var desiredPlaying = true
    private var switching = false
    private var closed = false
    private var autoplayTimer: Timer?
    private var queueLoading = false
    private var attemptedQueuePage: String?
    private var awaitingQueueEnd = false
    private var upcomingVideo: Video? {
        TVPlaybackPolicy.upcomingVideo(in: PlaybackQueue.shared, suggestion: nextVideo)
    }
    private let subtitle = UILabel()
    private var subtitleBottom: NSLayoutConstraint?
    private let status = UILabel()
    private let transport = TVTransportView()
    private var controlsTimer: Timer?
    private var playbackRate: Float = 1
    private var seekGeneration = 0
    private var pendingSeek: Double?


    init(video: Video, dependencies: ServiceDependencies, playlistQueue: Bool = false) {
        self.video = video
        self.queueUsesPlaylistBrowse = playlistQueue
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        player = avPlayer
        showsPlaybackControls = false
        configureTransport()
        allowsPictureInPicturePlayback = false
        speeds = AVPlaybackSpeed.systemDefaultSpeeds
        facade.context = self
        facade.watchtimeTracker.timeProvider = { [weak self] in self?.avPlayer.currentTime().seconds ?? 0 }
        facade.watchtimeTracker.durationProvider = { [weak self] in self?.avPlayer.currentItem?.duration.seconds ?? 0 }
        PlaybackBufferPolicy.configure(player: avPlayer)
        configureOverlays()
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                        queue: .main) { [weak self] time in self?.tick(time.seconds) }
        tracksObserver = NotificationCenter.default.addObserver(forName: .sourceAudioTracksDidChange,
                                                                 object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenus()
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            self?.saveProgress()
            self?.avPlayer.pause()
        }
        start(video)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { close() }
    }
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        transport.isHidden ? super.preferredFocusEnvironments : [transport.seekBar, transport.playButton]
    }

    private func configureTransport() {
        transport.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transport)
        NSLayoutConstraint.activate([
            transport.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            transport.heightAnchor.constraint(equalToConstant: 300)
        ])
        transport.playButton.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .primaryActionTriggered)
        transport.seekBar.onPlayPause = { [weak self] in self?.togglePlayback() }
        transport.seekBar.onSeek = { [weak self] seconds in
            guard let self else { return }
            self.seekGeneration += 1
            let generation = self.seekGeneration
            self.pendingSeek = seconds
            self.avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.seekGeneration == generation else { return }
                    self.pendingSeek = nil
                }
            }
            self.showControls()
        }
        transport.onInteraction = { [weak self] in self?.scheduleControlsHide() }
    }

    private func updateTimelineSegments() {
        transport.setSegments(SponsorBlockService.enabled ? segments : [])
    }

    private func togglePlayback() {
        if avPlayer.rate > 0 { avPlayer.pause() }
        else {
            if let duration = avPlayer.currentItem?.duration.seconds,
               duration.isFinite, avPlayer.currentTime().seconds >= duration - 0.2 {
                avPlayer.seek(to: .zero)
            }
            avPlayer.playImmediately(atRate: playbackRate)
        }
        showControls()
    }

    private func showControls() {
        let wasHidden = transport.isHidden
        transport.isHidden = false
        subtitleBottom?.constant = -324
        if wasHidden { setNeedsFocusUpdate(); updateFocusIfNeeded() }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.controlsTimer = nil
            // A menu owns focus while it is open; leave its underlying controls visible.
            guard self.avPlayer.rate > 0, self.transportContainsFocus else { return }
            self.hideControls()
        }
    }

    private func hideControls() {
        transport.isHidden = true
        subtitleBottom?.constant = -80
    }

    private var transportContainsFocus: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: transport)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .playPause }) {
            togglePlayback()
        } else if presses.contains(where: { $0.type == .menu }), !transport.isHidden {
            controlsTimer?.invalidate()
            controlsTimer = nil
            hideControls()
        } else if transport.isHidden, presses.contains(where: {
            [.select, .upArrow, .downArrow, .leftArrow, .rightArrow].contains($0.type)
        }) {
            showControls()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    private func configureOverlays() {
        subtitle.font = .systemFont(ofSize: 36, weight: .semibold)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 3
        subtitle.textColor = .white
        subtitle.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        subtitle.layer.cornerRadius = 8
        subtitle.clipsToBounds = true
        subtitle.isHidden = true
        status.font = .systemFont(ofSize: 30, weight: .medium)
        status.textColor = .white
        status.textAlignment = .center
        status.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        guard let overlay = contentOverlayView else { return }
        [subtitle, status].forEach {
            $0.isUserInteractionEnabled = false
            $0.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview($0)
        }
        let bottom = subtitle.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -324)
        subtitleBottom = bottom
        NSLayoutConstraint.activate([
            subtitle.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            bottom,
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8),
            status.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
    }
    private func start(_ next: Video) {
        saveProgress()
        cancellation.cancel()
        stopObservingCurrentItem()
        facade.reset()
        queueLoading = false
        attemptedQueuePage = nil
        awaitingQueueEnd = false
        cancellation = CancellationToken()
        let token = cancellation
        seekGeneration += 1
        pendingSeek = nil
        video = next
        transport.titleLabel.text = next.title
        transport.setSegments([])
        transport.update(position: 0, duration: 0, buffered: 0, playing: true)
        showControls()
        lastPosition = nil
        desiredPlaying = true
        switching = false
        nextVideo = nil
        captionTracks = []
        cues = []
        captionLanguage = nil
        subtitleGeneration += 1
        subtitle.isHidden = true
        segments = []
        manualSegment = nil
        skipped = []
        autoplayTimer?.invalidate()
        avPlayer.replaceCurrentItem(with: nil)
        resourceLoader = nil
        WatchProgressStore.shared.suppressResume = PlaybackQueue.shared.playlistId != nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        facade.start(videoId: next.id, apiClient: dependencies.watchService, cancellationToken: token)
        dependencies.watchService.fetchWatchPage(video: next, cancellationToken: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled, case .success(let page) = result else { return }
                self.video = page.video
                self.transport.titleLabel.text = page.video.title
                self.nextVideo = page.nextVideo
                if let videos = page.playlistVideos, !videos.isEmpty, !self.queueUsesPlaylistBrowse {
                    if PlaybackQueue.shared.playlistId != next.playlistId {
                        PlaybackQueue.shared.setQueue(videos, playlistId: next.playlistId,
                                                      title: page.playlistTitle, continuation: page.queueContinuation)
                    } else {
                        PlaybackQueue.shared.appendPage(FeedPage(videos: videos, continuation: page.queueContinuation))
                    }
                    PlaybackQueue.shared.seekTo(videoId: next.id)
                }
                self.rebuildMenus()
            }
        }
        loadSegments()
        rebuildMenus()
    }
    private func loadSegments() {
        let token = cancellation
        guard SponsorBlockService.enabled else { return }
        SponsorBlockService.shared.fetchSegments(videoId: video.id) { [weak self] result in
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                self?.segments = (try? result.get()) ?? []
                self?.updateTimelineSegments()
                self?.rebuildMenus()
            }
        }
    }
    func attachPrepared(_ prepared: PreparedPlayback, resumeAt: CMTime?) {
        guard !closed, !cancellation.isCancelled else { return }
        stopObservingCurrentItem()
        resourceLoader = prepared.resourceLoader
        PlaybackBufferPolicy.configure(item: prepared.item)
        prepared.item.externalMetadata = metadata()
        avPlayer.replaceCurrentItem(with: prepared.item)
        let saved = WatchProgressStore.shared.resumeSeconds(forVideoId: video.id, duration: prepared.duration)
        let position = resumeAt?.seconds ?? lastPosition ?? saved
        if let position = TVPlaybackPolicy.seekPosition(requested: position, preparedStart: prepared.startsAt) {
            avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        setCaptionTracks(prepared.captions)
        if prepared.captions.isEmpty {
            let token = cancellation
            dependencies.watchService.fetchCaptionTracks(videoId: video.id) { [weak self] tracks in
                DispatchQueue.main.async {
                    guard !token.isCancelled else { return }
                    self?.setCaptionTracks(tracks)
                }
            }
        }
        startObservingPlayerItem(prepared.item)
        switching = false
        status.isHidden = true
        if desiredPlaying { avPlayer.playImmediately(atRate: playbackRate) }
        rebuildMenus()
    }
    private func metadata() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = video.title as NSString
        let author = AVMutableMetadataItem()
        author.identifier = .commonIdentifierArtist
        author.value = video.channelName as NSString
        return [title, author]
    }
    func updateStatusLabel(_ text: String) {
        // Stream preparation reports progress from the playback transport queue.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusLabel(text)
            }
            return
        }
        guard !closed else { return }
        status.text = "  \(text)  "
        status.isHidden = false
    }
    func showPlaybackError(_ message: String) {
        guard !closed, presentedViewController == nil else { return }
        status.isHidden = true
        switching = false
        let alert = UIAlertController(title: "TV.playbackFailed".tvLocalized, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "TV.retry".tvLocalized, style: .default) { [weak self] _ in
            guard let self else { return }; self.start(self.video)
        })
        alert.addAction(UIAlertAction(title: "TV.close".tvLocalized, style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
    func startObservingPlayerItem(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.avPlayer.currentItem === item, item.status == .failed else { return }
                self.recover()
            }
        }
        notifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: item, queue: .main) { [weak self] _ in self?.ended() },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                   object: item, queue: .main) { [weak self] _ in self?.recover() },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                                   object: item, queue: .main) { [weak self] _ in self?.recover() }
        ]
    }
    func stopObservingPlayerItem(_ item: AVPlayerItem) { stopObservingCurrentItem() }
    private func stopObservingCurrentItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []
    }
    private func recover() {
        guard !closed, !switching else { return }
        lastPosition = avPlayer.currentTime().seconds
        desiredPlaying = avPlayer.timeControlStatus != .paused
        switching = true
        if !facade.recover(cancellationToken: cancellation) { showPlaybackError("player.error.playback".localized) }
    }
    func setCaptionTracks(_ tracks: [SubtitleTrack]) {
        captionTracks = tracks
        let language = captionLanguage ?? UserDefaults.standard.string(forKey: "TV.captions")
        if let language, let track = tracks.first(where: { $0.languageCode == language }) { selectCaption(track) }
        else { cues = []; subtitle.isHidden = true }
        rebuildMenus()
    }
    private func selectCaption(_ track: SubtitleTrack?) {
        subtitleGeneration += 1
        let generation = subtitleGeneration
        captionLanguage = track?.languageCode
        cues = []
        subtitle.isHidden = true
        guard let track else { return }
        SubtitleService.shared.load(track: track) { [weak self] cues in
            guard let self, !self.closed, self.subtitleGeneration == generation else { return }
            self.cues = cues
            if cues.isEmpty { self.updateStatusLabel("TV.captionsUnavailable".tvLocalized) }
        }
    }
    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let text = TVPlaybackPolicy.caption(at: seconds, cues: cues)
        subtitle.text = text.map { "  \($0)  " }
        subtitle.isHidden = text == nil
        saveProgress()
        let duration = avPlayer.currentItem?.duration.seconds ?? 0
        let buffered = avPlayer.currentItem?.loadedTimeRanges.compactMap {
            $0.timeRangeValue.end.seconds
        }.filter { $0.isFinite }.max() ?? 0
        transport.update(position: pendingSeek ?? seconds, duration: duration, buffered: buffered, playing: avPlayer.rate > 0)
        if SponsorBlockService.enabled, avPlayer.rate > 0,
           let segment = segments.first(where: {
               $0.actionType == "skip" && $0.startTime <= seconds && seconds < $0.endTime &&
               !skipped.contains($0.uuid) && SponsorBlockService.skipBehavior(for: $0.category) == .autoSkip
           }) {
            skipped.insert(segment.uuid)
            avPlayer.seek(to: CMTime(seconds: segment.endTime, preferredTimescale: 600))
        }
        let manual = SponsorBlockService.enabled ? segments.first {
            $0.actionType == "skip" && $0.startTime <= seconds && seconds < $0.endTime &&
            SponsorBlockService.skipBehavior(for: $0.category) == .showButton
        } : nil
        if manualSegment?.uuid != manual?.uuid {
            manualSegment = manual
            rebuildMenus()
        }
        let queue = PlaybackQueue.shared
        if queue.nextVideo == nil, queue.continuation != nil { loadQueuePage() }
    }
    private func saveProgress() {
        let seconds = avPlayer.currentTime().seconds
        guard let duration = avPlayer.currentItem?.duration.seconds,
              seconds.isFinite, duration.isFinite, duration > 0, seconds > 0 else { return }
        WatchProgressStore.shared.setLocalFraction(videoId: video.id, fraction: min(1, seconds / duration))
    }
    private func loadQueuePage() {
        let queue = PlaybackQueue.shared
        guard !queueLoading, let continuation = queue.continuation, continuation != attemptedQueuePage else { return }
        queueLoading = true
        attemptedQueuePage = continuation
        let token = cancellation
        let completion: (Result<FeedPage, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.queueLoading = false
                guard case .success(let page) = result else { return }
                queue.appendPage(page)
                self.rebuildMenus()
                if self.awaitingQueueEnd {
                    self.awaitingQueueEnd = false
                    self.ended()
                }
            }
        }
        if queueUsesPlaylistBrowse, let playlistId = queue.playlistId {
            dependencies.playlistService.fetchPlaylistVideos(playlistId: playlistId, continuation: continuation, completion: completion)
        } else {
            dependencies.watchService.fetchQueuePage(continuation: continuation, completion: completion)
        }
    }
    private func ended() {
        showControls()
        saveProgress()
        let enabled = PlaybackQueue.shared.playlistId == nil ? AutoplayPreference.isEnabled : AutoplayPreference.isMixEnabled
        guard enabled else { return }
        if PlaybackQueue.shared.playlistId != nil, upcomingVideo == nil,
           let token = PlaybackQueue.shared.continuation,
           queueLoading || token != attemptedQueuePage {
            awaitingQueueEnd = true
            loadQueuePage()
            return
        }
        guard let next = upcomingVideo else { return }
        if PlaybackQueue.shared.playlistId != nil { advance(next); return }
        let alert = UIAlertController(title: "TV.upNext".tvLocalized, message: next.title, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "TV.playNow".tvLocalized, style: .default) { [weak self] _ in self?.advance(next) })
        alert.addAction(UIAlertAction(title: "TV.cancel".tvLocalized, style: .cancel) { [weak self] _ in self?.autoplayTimer?.invalidate() })
        present(alert, animated: true)
        autoplayTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) { self?.advance(next) }
        }
    }
    private func advance(_ next: Video) {
        autoplayTimer?.invalidate()
        PlaybackQueue.shared.seekTo(videoId: next.id)
        start(next)
    }
    private func switchSource(_ operation: (@escaping (Result<PreparedPlayback, Error>) -> Void) -> Void) {
        guard !switching, !closed else { return }
        switching = true
        desiredPlaying = avPlayer.timeControlStatus != .paused
        lastPosition = avPlayer.currentTime().seconds
        let token = cancellation
        operation { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                switch result {
                case .success(let prepared): self.attachPrepared(prepared, resumeAt: nil)
                case .failure:
                    self.switching = false
                    self.showPlaybackError("player.error.playback".localized)
                }
            }
        }
    }
    private func rebuildMenus() {
        guard isViewLoaded else { return }
        var menus: [UIMenuElement] = []
        if let source = facade.activeVideoSource {
            let qualities = source.availableQualities.filter { ($0.height ?? 0) > 0 }
            if !qualities.isEmpty {
                menus.append(UIMenu(title: "player.menu.quality".localized, image: UIImage(systemName: "gearshape"), children: qualities.map { quality in
                    UIAction(title: quality.label, state: source.currentQuality == quality ? .on : .off) { [weak self] _ in
                        guard let self else { return }
                        self.switchSource { done in source.selectQuality(quality, resumeAt: self.avPlayer.currentTime().seconds, completion: done) }
                    }
                }))
            }
            if source.supportsAudioTrackSelection {
                menus.append(UIMenu(title: "player.menu.audioTrack".localized, image: UIImage(systemName: "waveform"), children: source.availableAudioTracks.map { track in
                    UIAction(title: track.displayName, state: source.currentAudioTrack == track ? .on : .off) { [weak self] _ in
                        guard let self else { return }
                        self.switchSource { done in source.selectAudioTrack(track, resumeAt: self.avPlayer.currentTime().seconds, completion: done) }
                    }
                }))
            }
        }
        var captions: [UIMenuElement] = [UIAction(title: "player.subtitles.off".localized) { [weak self] _ in
            UserDefaults.standard.removeObject(forKey: "TV.captions")
            self?.selectCaption(nil)
        }]
        captions += captionTracks.map { track in
            UIAction(title: track.name, state: captionLanguage == track.languageCode ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(track.languageCode, forKey: "TV.captions")
                self?.selectCaption(track)
            }
        }
        menus.append(UIMenu(title: "player.menu.subtitles".localized, image: UIImage(systemName: "captions.bubble"), children: captions))
        menus.append(UIAction(title: "SponsorBlock", image: UIImage(systemName: "forward.end"),
                              state: SponsorBlockService.enabled ? .on : .off) { [weak self] _ in
            SponsorBlockService.enabled.toggle()
            self?.loadSegments()
            self?.updateTimelineSegments()
            self?.rebuildMenus()
        })
        if let segment = manualSegment {
            menus.append(UIAction(title: "TV.skipSegment".tvLocalized(with: segment.category.displayName), image: UIImage(systemName: "forward")) { [weak self] _ in
                self?.avPlayer.seek(to: CMTime(seconds: segment.endTime, preferredTimescale: 600))
            })
        }
        let queue = PlaybackQueue.shared
        if queue.currentIndex > 0 {
            menus.append(UIAction(title: "TV.previous".tvLocalized, image: UIImage(systemName: "backward.end")) { [weak self] _ in
                self?.advance(queue.videos[queue.currentIndex - 1])
            })
        }
        if let next = upcomingVideo {
            menus.append(UIAction(title: "TV.next".tvLocalized, image: UIImage(systemName: "forward.end")) { [weak self] _ in self?.advance(next) })
        }
        if let channelId = video.channelId {
            menus.append(UIAction(title: video.channelName, image: UIImage(systemName: "person.crop.rectangle")) { [weak self] _ in
                guard let self else { return }
                self.onChannelRequested?(channelId, self.video.channelName)
            })
        }
        menus.insert(UIMenu(title: "TV.playbackSpeed".tvLocalized, image: UIImage(systemName: "speedometer"), children:
            [Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { rate in
                UIAction(title: "\(rate)×", state: playbackRate == rate ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.playbackRate = rate
                    if self.avPlayer.rate > 0 { self.avPlayer.rate = rate }
                    self.rebuildMenus()
                    self.showControls()
                }
            }), at: 0)
        transport.settingsButton.menu = UIMenu(children: menus)
    }
    private func close() {
        guard !closed else { return }
        closed = true
        controlsTimer?.invalidate()
        controlsTimer = nil
        saveProgress()
        cancellation.cancel()
        autoplayTimer?.invalidate()
        avPlayer.pause()
        stopObservingCurrentItem()
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let tracksObserver { NotificationCenter.default.removeObserver(tracksObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        facade.reset()
        avPlayer.replaceCurrentItem(with: nil)
        resourceLoader = nil
        PlaybackProgress.report = nil
        WatchProgressStore.shared.suppressResume = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    deinit { close() }
}
