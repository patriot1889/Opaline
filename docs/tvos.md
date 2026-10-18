# Opaline on Apple TV

OpalineTV is a separate UIKit app for tvOS 17 and later, including Apple TV HD and Apple TV 4K. It shares the API clients, OAuth device flow, image loader, source fallback chain, HLS/SABR delivery, and watch-progress services with the iOS app. The iOS target continues to support iOS 12.

## Build and install

1. Install Xcode with the tvOS platform component (Xcode → Settings → Components). For command-line setup, use `xcodebuild -downloadPlatform tvOS`.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` if it does not exist.
3. Set `DEVELOPMENT_TEAM` and optionally `OPALINE_TV_BUNDLE_IDENTIFIER` in that local configuration. The TV identifier defaults to `com.example.OpalineTV` and is independent of the iOS identifier.
4. Open `Opaline.xcodeproj`, select **OpalineTV**, and choose an Apple TV simulator or a paired physical Apple TV. For a physical device, let Xcode create its tvOS provisioning profile, then run the scheme.

Simulator build:

```sh
xcodebuild -project Opaline.xcodeproj -scheme OpalineTV \
  -destination 'generic/platform=tvOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Fixture tests (substitute an available simulator name if needed):

```sh
xcodebuild -project Opaline.xcodeproj -scheme OpalineTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  CODE_SIGNING_ALLOWED=NO test
```

Unsigned device archive, suitable for inspecting the build but requiring signing before installation:

```sh
xcodebuild -project Opaline.xcodeproj -scheme OpalineTV \
  -destination 'generic/platform=tvOS' -configuration Release \
  -archivePath build/OpalineTV.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

## TV behavior

Use directional remote input to move focus and Select to open a card. Back/Menu returns through the navigation stack and AVKit's playback controls. Home, Search, Subscriptions, Library, and Settings have separate navigation stacks. Sign-in displays a verification URL, QR code, and device code to complete on another device; anonymous browsing is available. Account-only lists offer sign-in while signed out.

Playback uses the native AVKit transport bar, with quality, dubbed audio, external captions, SponsorBlock, previous/next, and channel actions. Quality menus reflect the stream's decodable formats; hardware model alone does not guarantee 4K playback. Playlist playback continues through its queue. Suggested autoplay presents a cancellable five-second prompt. Captions load through the existing VTT/XML service and appear in a noninteractive overlay.

Search loads results automatically after a short typing pause. Suggestions occupy a compact row above the results and do not interrupt loading or pagination.

Settings cover account, language/region, appearance, autoplay, quality, preferred audio/captions, SponsorBlock categories, and the solver server. New TV-specific strings currently fall back to English when a translation is unavailable.

Shorts, comments, offline downloads, the Open In share extension, phone gestures, notifications, and background audio are outside this first TV release. The TV target does not embed the iOS extension. Static Top Shelf artwork is included; there is no dynamic Top Shelf extension.

## Storage and code sharing

Credentials use the existing Keychain flow. Settings, the last 20 searches, and bounded recent watch progress use UserDefaults. Signed-in history sync uses the existing YouTube services. Image disk cache is limited to 64 MiB and feed cache to 16 MiB on tvOS. Cache directories can disappear between sessions and are recreated on writes. Streaming buffers and servers are released when playback ends; no offline download store is compiled into the TV target.

Shared Swift files have explicit membership under **TV Shared Sources** in Xcode. New files in `OpalineTV` and `OpalineTVTests` are synchronized with their respective targets. Shared service dependencies are separate from the iOS screen factories. When adding shared source files, add TV membership explicitly and build both targets.

The `Build Apple TV` workflow builds Debug/Release simulator configurations, runs fixtures, and uploads an unsigned Release archive. Existing iOS release publishing remains separate.

## Device acceptance checks

Before distributing, verify on physical Apple TV HD and Apple TV 4K with both touch-surface and clickpad remotes:

- Sign-in success, code expiry/retry, cancellation, anonymous mode, sign-out, and relaunch.
- Every tab and menu using remote input only; search keyboard/suggestions/filters; channel and playlist navigation; paging, retry, and focus restoration after playback.
- Live and on-demand playback; seek/resume; paused and playing quality/audio switches; external subtitle timing after seeks; codec fallback and unavailable videos.
- Playlist boundaries, queue continuation, previous/next, suggested autoplay cancellation, and SponsorBlock auto/manual skip behavior.
- Network interruption and recovery, leaving the player during resolution, cache eviction, and relaunch without cached files.

Simulator fixtures do not certify real YouTube authentication, stream availability, hardware decoding, or physical remote behavior. Those require the device checks above.
