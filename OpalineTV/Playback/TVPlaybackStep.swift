import Foundation

/// TV composition for the shared source chain. Stable IDs preserve saved settings.
struct PlaybackStep {
    let id: String
    let title: String
    let requiresSignIn: Bool
    var deliveryPreference: PlaybackDeliveryPreference = .generatedHLS
    let make: (WatchService) -> VideoSource
}

struct PlaybackStepRegistry {
    static let `default` = PlaybackStepRegistry(steps: [
        PlaybackStep(id: "visionos.hls", title: "TV.source.nativeHLS".tvLocalized,
                     requiresSignIn: false, deliveryPreference: .native) {
            NativeHLSSource(apiClient: $0)
        },
        adaptive("visionos.range", title: "TV.source.ranges", delivery: ByteRangeDeliveryFactory()),
        adaptive("visionos.sabr", title: "TV.source.sabr", delivery: SABRDeliveryFactory()),
        PlaybackStep(id: "tv.sabr", title: "TV.source.signedInSABR".tvLocalized, requiresSignIn: true) {
            InnertubeVideoSource(apiClient: $0, client: TVClient(), name: "tv.sabr",
                                 deliveryFactory: SABRDeliveryFactory())
        },
        adaptive("visionos.webm", title: "TV.source.webm", delivery: WebMVP9DeliveryFactory(),
                 preference: .remuxedWebM),
        PlaybackStep(id: "progressive", title: "TV.source.progressive".tvLocalized,
                     requiresSignIn: false, deliveryPreference: .native) {
            ProgressiveSource(apiClient: $0)
        }
    ])

    let steps: [PlaybackStep]

    func step(id: String) -> PlaybackStep? { steps.first { $0.id == id } }

    private static func adaptive(
        _ id: String, title: String, delivery: StreamDeliveryFactory,
        preference: PlaybackDeliveryPreference = .generatedHLS
    ) -> PlaybackStep {
        PlaybackStep(id: id, title: title.tvLocalized, requiresSignIn: false,
                     deliveryPreference: preference) {
            InnertubeVideoSource(apiClient: $0, client: VisionOSClient(), name: id,
                                 deliveryFactory: delivery)
        }
    }
}
