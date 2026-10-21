import AVKit
import UIKit

/// The TV host shares stream preparation with iOS and owns its remote-driven presentation.
final class TVPlayerController: UIViewController, PlaybackContext, UIGestureRecognizerDelegate {
    var onChannelRequested: ((String, String) -> Void)?
    private let dependencies: ServiceDependencies
    private let queueUsesPlaylistBrowse: Bool
    private var video: Video
    private let facade = PlaybackFacade()
    private let avPlayer = AVPlayer()
    private let playbackController = AVPlayerViewController()
    private let displayMode = TVPlaybackDisplayMode()
    let chrome = TVPlayerChrome()
    private var panel: TVPlayerPanel?
    private var watchPage: WatchPage?
    private var commentsPage: CommentsPage?
    private var loadedComments: [Comment] = []
    private var commentsLoading = false
    private var engagementLoading = false
    private var likeStatus: LikeStatus?
    private var subscribed = false
    private var controlsVisible = true
    private var hideControlsTimer: Timer?
    private var panelShowsComments = false
    private var handledPresses = Set<UIPress.PressType>()
    private let menuPressRecognizer = UITapGestureRecognizer()
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
    private var segmentRequestGeneration = 0
    private var skipped = Set<String>()
    private var manualSegment: SponsorBlockSegment?
    private var nextVideo: Video?
    private var lastPosition: Double?
    private var desiredPlaying = true
    private var switching = false
    private var closed = false
    private var upNextController: TVUpNextController?
    private var autoplayGeneration = 0
    private var queueLoading = false
    private var attemptedQueuePage: String?
    private var awaitingQueueEnd = false
    private var upcomingVideo: Video? {
        TVPlaybackPolicy.upcomingVideo(in: PlaybackQueue.shared, suggestion: nextVideo)
    }
    private let subtitle = UILabel()
    private let status = UILabel()

    init(video: Video, dependencies: ServiceDependencies, playlistQueue: Bool = false) {
        self.video = video
        self.queueUsesPlaylistBrowse = playlistQueue
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
        // Back is handled explicitly below, including when UIKit would dismiss this modal.
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        // Resizing for side panels must not relinquish the video's matched display mode.
        playbackController.appliesPreferredDisplayCriteriaAutomatically = false
        playbackController.showsPlaybackControls = false
        playbackController.view.isUserInteractionEnabled = false
        playbackController.allowsPictureInPicturePlayback = false
        addChild(playbackController)
        // AVKit lays out its internal views as soon as it receives a player.
        // Give it the host's size first instead of an initial zero-sized frame.
        playbackController.view.frame = view.bounds
        view.addSubview(playbackController.view)
        playbackController.didMove(toParent: self)
        playbackController.player = avPlayer
        view.addSubview(chrome)
        configureControls()
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
            self?.dismissUpNext()
            self?.avPlayer.pause()
        }
        start(video)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !closed, let manager = view.window?.avDisplayManager { displayMode.bind(to: manager) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { close() }
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
        guard let overlay = playbackController.contentOverlayView else { return }
        [subtitle, status].forEach {
            $0.isUserInteractionEnabled = false
            $0.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview($0)
        }
        NSLayoutConstraint.activate([
            subtitle.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            subtitle.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -180),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8),
            status.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
    }
    private func start(_ next: Video) {
        saveProgress()
        displayMode.cancelPendingUpdate()
        cancellation.cancel()
        stopObservingCurrentItem()
        facade.reset()
        queueLoading = false
        attemptedQueuePage = nil
        awaitingQueueEnd = false
        cancellation = CancellationToken()
        let token = cancellation
        video = next
        engagementLoading = false
        likeStatus = nil
        subscribed = false
        watchPage = nil
        commentsPage = nil
        loadedComments = []
        commentsLoading = false
        closePanel()
        chrome.update(video: next)
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
        chrome.updateSponsorSegments([])
        manualSegment = nil
        skipped = []
        dismissUpNext()
        avPlayer.replaceCurrentItem(with: nil)
        resourceLoader = nil
        WatchProgressStore.shared.suppressResume = PlaybackQueue.shared.playlistId != nil
        TVPlaybackAudioSession.activate { [weak self] error in
            guard let self, !self.closed, !token.isCancelled else { return }
            if let error {
                AppLog.player("TV audio session activation failed: \(error.localizedDescription)")
                self.showPlaybackError("player.error.playback".localized)
                return
            }
            self.facade.start(videoId: next.id, apiClient: self.dependencies.watchService, cancellationToken: token)
        }
        dependencies.watchService.fetchWatchPage(video: next, cancellationToken: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled, case .success(let page) = result else { return }
                self.video = page.video
                self.watchPage = page
                self.likeStatus = page.likeStatus
                self.subscribed = page.isSubscribed
                self.chrome.update(video: page.video)
                if self.panel != nil, !self.panelShowsComments { self.populateDescription() }
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
        segmentRequestGeneration += 1
        let generation = segmentRequestGeneration
        let token = cancellation
        guard SponsorBlockService.enabled else {
            segments = []
            manualSegment = nil
            chrome.updateSponsorSegments([])
            return
        }
        SponsorBlockService.shared.fetchSegments(videoId: video.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled, !self.closed, SponsorBlockService.enabled,
                      self.segmentRequestGeneration == generation else { return }
                self.segments = (try? result.get()) ?? []
                self.rebuildMenus()
            }
        }
    }
    func attachPrepared(_ prepared: PreparedPlayback, resumeAt: CMTime?) {
        guard !closed, !cancellation.isCancelled else { return }
        displayMode.cancelPendingUpdate()
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
        if desiredPlaying { avPlayer.play() }
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
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, !self.closed, self.avPlayer.currentItem === item else { return }
                switch item.status {
                case .readyToPlay: self.displayMode.update(for: item.asset)
                case .failed: self.recover()
                default: break
                }
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
        chrome.updateTime(seconds: seconds, total: avPlayer.currentItem?.duration.seconds ?? 0,
                          playing: avPlayer.timeControlStatus == .playing)
        saveProgress()
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
        guard upNextController == nil, presentedViewController == nil else { return }
        let generation = autoplayGeneration
        let overlay = TVUpNextController(video: next)
        upNextController = overlay
        overlay.onPlay = { [weak self, weak overlay] in
            guard let self, self.upNextController === overlay else { return }
            self.upNextController = nil
            overlay?.dismiss(animated: true) { [weak self] in
                guard let self, !self.closed, self.autoplayGeneration == generation else { return }
                self.advance(next)
            }
        }
        overlay.onCancel = { [weak self] in
            self?.dismissUpNext()
        }
        present(overlay, animated: true)
    }

    private func dismissUpNext() {
        autoplayGeneration += 1
        guard let overlay = upNextController else { return }
        upNextController = nil
        overlay.stopCountdown()
        overlay.onPlay = nil
        overlay.onCancel = nil
        overlay.dismiss(animated: false)
    }

    private func advance(_ next: Video) {
        dismissUpNext()
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
        chrome.updateSponsorSegments(SponsorBlockService.enabled ? segments.filter {
            SponsorBlockService.skipBehavior(for: $0.category) != .disabled
        } : [])
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
        let speedMenu = UIMenu(title: "TV.player.speed".tvLocalized, image: UIImage(systemName: "speedometer"), children: [0.5, 0.75, 1, 1.25, 1.5, 2].map { speed in
            UIAction(title: "\(speed)×", state: avPlayer.defaultRate == Float(speed) ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.avPlayer.defaultRate = Float(speed)
                if self.avPlayer.rate > 0 { self.avPlayer.rate = Float(speed) }
                self.rebuildMenus()
            }
        })
        chrome.settings.menu = UIMenu(children: menus + [speedMenu])
        chrome.captions.menu = UIMenu(title: "player.menu.subtitles".localized, children: captions)
        chrome.previous.isEnabled = queue.currentIndex > 0
        chrome.nextButton.isEnabled = upcomingVideo != nil
        chrome.channel.isEnabled = video.channelId != nil
        chrome.subscribe.isEnabled = video.channelId != nil && !engagementLoading
        chrome.like.isEnabled = !engagementLoading
        chrome.dislike.isEnabled = !engagementLoading
        chrome.like.configuration?.image = UIImage(systemName: likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
        chrome.dislike.configuration?.image = UIImage(systemName: likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        chrome.subscribe.configuration?.image = UIImage(systemName: subscribed ? "bell.fill" : "bell")
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        chrome.frame = bounds
        if let panel {
            let width = bounds.width * 0.61
            let height = width * 9 / 16
            playbackController.view.frame = CGRect(x: 32, y: (bounds.height - height) / 2, width: width, height: height)
            playbackController.view.layer.cornerRadius = 28
            playbackController.view.clipsToBounds = true
            panel.view.frame = CGRect(x: bounds.width * 0.65, y: 40, width: bounds.width * 0.33, height: bounds.height - 40)
        } else {
            playbackController.view.frame = bounds
            playbackController.view.layer.cornerRadius = 0
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let panel { return [panel] }
        return controlsVisible ? [chrome.play] : [view]
    }

    private func configureControls() {
        menuPressRecognizer.addTarget(self, action: #selector(handleMenuPress(_:)))
        menuPressRecognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuPressRecognizer.allowedTouchTypes = []
        menuPressRecognizer.delegate = self
        view.addGestureRecognizer(menuPressRecognizer)
        chrome.play.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .primaryActionTriggered)
        chrome.previous.addAction(UIAction { [weak self] _ in
            let queue = PlaybackQueue.shared
            guard queue.currentIndex > 0 else { return }
            self?.advance(queue.videos[queue.currentIndex - 1])
        }, for: .primaryActionTriggered)
        chrome.nextButton.addAction(UIAction { [weak self] _ in
            guard let self, let next = self.upcomingVideo else { return }
            self.advance(next)
        }, for: .primaryActionTriggered)
        chrome.descriptionButton.addAction(UIAction { [weak self] _ in self?.openPanel(comments: false) }, for: .primaryActionTriggered)
        chrome.comments.addAction(UIAction { [weak self] _ in self?.openPanel(comments: true) }, for: .primaryActionTriggered)
        chrome.like.addAction(UIAction { [weak self] _ in self?.rateVideo(.like) }, for: .primaryActionTriggered)
        chrome.dislike.addAction(UIAction { [weak self] _ in self?.rateVideo(.dislike) }, for: .primaryActionTriggered)
        chrome.subscribe.addAction(UIAction { [weak self] _ in self?.toggleSubscription() }, for: .primaryActionTriggered)
        chrome.channel.addAction(UIAction { [weak self] _ in self?.openChannel() }, for: .primaryActionTriggered)
        chrome.timeline.addAction(UIAction { [weak self] _ in self?.togglePlayback(keepingFocus: true) }, for: .primaryActionTriggered)
        chrome.timeline.onSeekTo = { [weak self] seconds in
            guard let self, let total = self.avPlayer.currentItem?.duration.seconds, total.isFinite else { return }
            let target = min(total, max(0, seconds))
            self.avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            self.scheduleHideControls()
        }
        chrome.timeline.onScrubbingChanged = { [weak self] scrubbing in
            guard let self else { return }
            if scrubbing {
                self.hideControlsTimer?.invalidate()
                self.avPlayer.pause()
            } else {
                if self.desiredPlaying { self.avPlayer.play() }
                self.scheduleHideControls()
            }
        }
        chrome.onInteraction = { [weak self] in self?.scheduleHideControls() }
        for direction: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(revealControls))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === menuPressRecognizer { return presentedViewController == nil }
        // These gestures only reveal hidden controls. Visible controls handle their own input.
        return panel == nil && !controlsVisible
    }

    private func requireAccount() -> Bool {
        guard TVAccountStore.shared.activeAccount == nil else { return true }
        let alert = UIAlertController(title: "TV.player.signInRequired".tvLocalized,
                                      message: "TV.player.signInMessage".tvLocalized, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "TV.close".tvLocalized, style: .cancel))
        present(alert, animated: true)
        return false
    }

    private func rateVideo(_ status: LikeStatus) {
        guard !engagementLoading, requireAccount() else { return }
        let nextStatus: LikeStatus = likeStatus == status ? .indifferent : status
        performEngagement(update: { [weak self] in self?.likeStatus = nextStatus }) { done in
            switch nextStatus {
            case .like: dependencies.engagementService.sendLike(videoId: video.id, completion: done)
            case .dislike: dependencies.engagementService.sendDislike(videoId: video.id, completion: done)
            case .indifferent: dependencies.engagementService.removeLike(videoId: video.id, completion: done)
            }
        }
    }

    private func toggleSubscription() {
        guard !engagementLoading, let channelId = video.channelId, requireAccount() else { return }
        let nextSubscribed = !subscribed
        performEngagement(update: { [weak self] in self?.subscribed = nextSubscribed }) { done in
            if nextSubscribed {
                dependencies.engagementService.subscribeToChannel(channelId: channelId, cancellationToken: cancellation, completion: done)
            } else {
                dependencies.engagementService.unsubscribeFromChannel(channelId: channelId, cancellationToken: cancellation, completion: done)
            }
        }
    }

    private func performEngagement(update: @escaping () -> Void,
                                   operation: (@escaping (Result<Void, Error>) -> Void) -> Void) {
        engagementLoading = true
        rebuildMenus()
        let token = cancellation
        operation { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.engagementLoading = false
                if case .success = result { update() }
                else {
                    let alert = UIAlertController(title: "TV.player.actionFailed".tvLocalized, message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "TV.close".tvLocalized, style: .cancel))
                    if self.presentedViewController == nil { self.present(alert, animated: true) }
                }
                self.rebuildMenus()
            }
        }
    }

    private func openChannel() {
        guard let id = video.channelId else { return }
        onChannelRequested?(id, video.channelName)
    }

    private func togglePlayback(keepingFocus: Bool = false) {
        if avPlayer.timeControlStatus == .paused { desiredPlaying = true; avPlayer.play() }
        else { desiredPlaying = false; avPlayer.pause() }
        chrome.updateTime(seconds: avPlayer.currentTime().seconds, total: avPlayer.currentItem?.duration.seconds ?? 0,
                          playing: desiredPlaying)
        if keepingFocus { scheduleHideControls() }
        else { showControls() }
    }

    @objc private func revealControls() {
        guard panel == nil, !controlsVisible else { return }
        showControls()
    }

    private func showControls() {
        controlsVisible = true
        chrome.isHidden = panel != nil
        setNeedsFocusUpdate()
        scheduleHideControls()
    }

    private func hideControls() {
        chrome.timeline.endScrubbing(cancelled: true)
        controlsVisible = false
        chrome.isHidden = true
        hideControlsTimer?.invalidate()
        setNeedsFocusUpdate()
    }

    @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        if panel != nil { closePanel() }
        else if controlsVisible { hideControls() }
        else { dismiss(animated: true) }
    }

    private func scheduleHideControls() {
        hideControlsTimer?.invalidate()
        guard panel == nil, desiredPlaying, !chrome.timeline.isScrubbing else { return }
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
            guard let self, self.presentedViewController == nil,
                  self.avPlayer.timeControlStatus == .playing else { return }
            self.hideControls()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            // The recognizer handles Back on release. Do not also change state on press-down.
            handledPresses.formUnion(presses.map(\.type))
        } else if presses.contains(where: { $0.type == .playPause || ($0.type == .select && panel == nil && !controlsVisible) }) {
            handledPresses.formUnion(presses.map(\.type))
            togglePlayback()
        } else if panel == nil, !controlsVisible {
            handledPresses.formUnion(presses.map(\.type))
            showControls()
        } else { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { !handledPresses.contains($0.type) }
        presses.forEach { handledPresses.remove($0.type) }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { !handledPresses.contains($0.type) }
        if !remaining.isEmpty { super.pressesChanged(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { !handledPresses.contains($0.type) }
        presses.forEach { handledPresses.remove($0.type) }
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    func openPanel(comments: Bool) {
        closePanel()
        panelShowsComments = comments
        let controller = TVPlayerPanel(style: .plain)
        panel = controller
        addChild(controller)
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        hideControlsTimer?.invalidate()
        chrome.isHidden = true
        if comments {
            controller.panelTitle = "TV.player.comments".tvLocalized + (watchPage?.commentCount.map { " \($0)" } ?? "")
            populateComments()
            if commentsPage == nil { loadComments() }
        } else { populateDescription() }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    func closePanel() {
        guard let panel else { return }
        panel.willMove(toParent: nil)
        panel.view.removeFromSuperview()
        panel.removeFromParent()
        self.panel = nil
        view.setNeedsLayout()
        showControls()
    }

    private func populateDescription() {
        guard let panel else { return }
        panel.panelTitle = video.title
        let stats = [watchPage?.likeCount.map { "\($0) " + "TV.player.likes".tvLocalized }, video.viewCount, video.publishedAt]
            .compactMap { $0 }.joined(separator: "    ·    ")
        var cards = [TVPlayerPanel.Card(title: stats, body: ""),
                     TVPlayerPanel.Card(title: video.channelName, body: watchPage?.channelInfo?.subscriberCountText ?? "",
                                        avatarURL: video.channelAvatarURL ?? watchPage?.channelInfo?.avatarURL,
                                        action: { [weak self] in self?.openChannel() })]
        let description = watchPage?.description ?? "TV.player.noDescription".tvLocalized
        cards.append(TVPlayerPanel.Card(title: "TV.player.description".tvLocalized, body: description))
        cards.append(TVPlayerPanel.Card(title: "TV.player.comments".tvLocalized,
                                        body: watchPage?.commentCount ?? "", action: { [weak self] in self?.openPanel(comments: true) }))
        panel.cards = cards
    }

    private func populateComments() {
        guard panelShowsComments, let panel else { return }
        var cards: [TVPlayerPanel.Card] = []
        for comment in loadedComments {
            cards.append(TVPlayerPanel.Card(
                title: [comment.isPinned ? "📌" : nil, comment.authorName, comment.publishedTime]
                    .compactMap { $0 }.joined(separator: " · "),
                body: comment.content,
                footer: [comment.likeCount.map { "♡ \($0)" }, comment.replyCount.map { "▢ \($0)" }]
                    .compactMap { $0 }.joined(separator: "    "),
                avatarURL: comment.authorAvatarURL))
        }
        if cards.isEmpty {
            cards = [TVPlayerPanel.Card(title: "TV.player.comments".tvLocalized,
                                       body: (commentsPage == nil ? "TV.player.loadingComments" : "TV.player.noComments").tvLocalized)]
        }
        if commentsPage?.continuation != nil {
            cards.append(TVPlayerPanel.Card(title: "TV.player.moreComments".tvLocalized, body: "", action: { [weak self] in self?.loadComments() }))
        }
        panel.cards = cards
    }

    private func loadComments() {
        guard !commentsLoading, commentsPage == nil || commentsPage?.continuation != nil else { return }
        commentsLoading = true
        let token = cancellation
        dependencies.watchService.fetchComments(videoId: video.id, continuation: commentsPage?.continuation,
                                                 cancellationToken: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.commentsLoading = false
                switch result {
                case .success(let page):
                    self.commentsPage = page
                    var ids = Set(self.loadedComments.map(\.id))
                    self.loadedComments += page.comments.filter { ids.insert($0.id).inserted }
                    self.populateComments()
                case .failure:
                    guard self.panelShowsComments else { return }
                    self.panel?.cards = [TVPlayerPanel.Card(title: "TV.player.commentsFailed".tvLocalized,
                        body: "TV.retry".tvLocalized, action: { [weak self] in self?.loadComments() })]
                }
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        displayMode.restore()
        hideControlsTimer?.invalidate()
        saveProgress()
        cancellation.cancel()
        dismissUpNext()
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
        TVPlaybackAudioSession.deactivate()
    }
    deinit { close() }
}
