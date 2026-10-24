import AVFoundation
import Foundation

/// Plays the server's HLS ladder directly, independently of DASH/SABR.
/// Failures return to the user's chain instead of silently choosing DASH.
final class NativeHLSSource: VideoSource {
    struct Manifest {
        let info: DirectPlaybackInfo
        let url: URL
        let text: String
        let headers: [String: String]
        let variants: [LiveHLSVariant]
    }

    private static var unavailable: Error {
        NSError(domain: "NativeHLSSource", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No playable native HLS rendition"
        ])
    }

    let name = "visionos.hls"
    var supportsQualitySelection: Bool { !availableQualities.isEmpty }
    private(set) var availableQualities: [VideoQuality] = []
    private(set) var currentQuality: VideoQuality?
    var currentCodecs: String? {
        manifest?.variants.first { $0.quality == currentQuality }?.codecs
    }

    private let apiClient: WatchService
    private let transport: HTTPTransport
    private let client: PlaybackClient = VisionOSClient()
    private var manifest: Manifest?
    private var generation = 0

    init(apiClient: WatchService, transport: HTTPTransport = ServiceContainer.mediaTransport) {
        self.apiClient = apiClient
        self.transport = transport
    }

    func loadPlayback(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        releaseResources()
        let requestGeneration = generation
        fetchManifest(videoId: videoId, cancellation: cancellation) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration,
                      cancellation?.isCancelled != true else {
                    return
                }
                completion(result.flatMap { manifest in
                    self.manifest = manifest
                    self.availableQualities = manifest.variants.map(\.quality)
                    let cap = VideoQualityStore.maxHeight ?? Int.max
                    guard let variant = manifest.variants.first(where: {
                        ($0.quality.height ?? 0) <= cap
                    }) ?? manifest.variants.last else {
                        return .failure(Self.unavailable)
                    }
                    return self.prepare(variant)
                })
            }
        }
    }

    func selectQuality(
        _ quality: VideoQuality,
        resumeAt: Double?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard let variant = manifest?.variants.first(where: { $0.quality == quality }) else {
            completion(.failure(Self.unavailable))
            return
        }
        // Native HTTP HLS seeks normally after the shell attaches the item.
        completion(prepare(variant))
    }

    func probeQualities(videoId: String, completion: @escaping ([VideoQuality]) -> Void) {
        fetchManifest(videoId: videoId, cancellation: nil) { result in
            let qualities = (try? result.get().variants.map(\.quality)) ?? []
            DispatchQueue.main.async { completion(qualities) }
        }
    }

    func releaseResources() {
        generation += 1
        manifest = nil
        availableQualities = []
        currentQuality = nil
    }

    private func fetchManifest(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        apiClient.fetchDirectPlayback(
            videoId: videoId, client: client, poToken: nil, cancellationToken: cancellation
        ) { [weak self] result in
            guard let self, cancellation?.isCancelled != true else {
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let info):
                self.fetchPlaylist(info: info, cancellation: cancellation, completion: completion)
            }
        }
    }

    private func fetchPlaylist(
        info: DirectPlaybackInfo,
        cancellation: CancellationToken?,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        guard let url = info.hlsManifestURL else {
            completion(.failure(Self.unavailable))
            return
        }
        let headers = client.streamHeaders(visitorData: info.visitorData)
        let request = HTTPRequest(
            method: .get, url: url, headers: headers, sendsCookies: false, isPlayback: true
        )
        transport.send(request, cancellationToken: cancellation) { result in
            guard cancellation?.isCancelled != true else {
                return
            }
            completion(result.flatMap { response in
                guard (200..<300).contains(response.status),
                      let text = String(data: response.data, encoding: .utf8),
                      text.hasPrefix("#EXTM3U") else {
                    return .failure(Self.unavailable)
                }
                let variants = NativeHLSCodecs.variants(playlist: text, baseURL: url)
                AppLog.player("native HLS: \(variants.count) playable tiers,"
                    + " hw vp9=\(NativeHLSCodecs.isVP9HardwareSupported)")
                guard !variants.isEmpty else {
                    return .failure(Self.unavailable)
                }
                return .success(Manifest(
                    info: info, url: url, text: text, headers: headers, variants: variants
                ))
            })
        }
    }

    private func prepare(_ variant: LiveHLSVariant) -> Result<PreparedPlayback, Error> {
        guard let manifest,
              let url = URL(string: "\(HLSGenerator.scheme)://native-master.m3u8") else {
            return .failure(Self.unavailable)
        }
        let text = LiveHLSVariants.manifest(
            keeping: variant, playlist: manifest.text, baseURL: manifest.url
        )
        let loader = HLSPlaylistLoader()
        loader.register(path: "native-master.m3u8", content: text)
        let asset = AVURLAsset(
            url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": manifest.headers]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.loaderQueue)
        let item = AVPlayerItem(asset: asset)
        PlaybackBufferPolicy.configure(item: item)
        currentQuality = variant.quality
        AppLog.player("native HLS: \(variant.quality.label) codecs=\(variant.codecs)")
        return .success(PreparedPlayback(
            item: item,
            resourceLoader: loader,
            captions: manifest.info.captionTracks,
            duration: manifest.info.duration
        ))
    }
}
