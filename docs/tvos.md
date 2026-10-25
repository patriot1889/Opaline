# Opaline on Apple TV

OpalineTV is a separate UIKit app for tvOS 17 and later, including Apple TV HD and Apple TV 4K. It references unchanged upstream API clients, models, networking, image loading, source fallback chain, and HLS/SABR delivery. Authentication and watch-progress storage have TV-specific implementations. The iOS target continues to support iOS 12.

## Build and install

1. Install Xcode with the tvOS platform component (Xcode → Settings → Components). For command-line setup, use `xcodebuild -downloadPlatform tvOS`.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` if it does not exist.
3. Set `DEVELOPMENT_TEAM` and optionally add `OPALINE_TV_BUNDLE_IDENTIFIER` in that local configuration. The TV identifier defaults to `com.example.OpalineTV` and is independent of the iOS identifier.
4. Open `OpalineTV.xcodeproj`, select **OpalineTV**, and choose an Apple TV simulator or a paired physical Apple TV. For a physical device, let Xcode create its tvOS provisioning profile, then run the scheme.

Simulator build:

```sh
xcodebuild -project OpalineTV.xcodeproj -scheme OpalineTV \
  -destination 'generic/platform=tvOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Fixture tests (substitute an available simulator name if needed):

```sh
xcodebuild -project OpalineTV.xcodeproj -scheme OpalineTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  CODE_SIGNING_ALLOWED=NO test
```

Unsigned device archive, suitable for inspecting the build but requiring signing before installation:

```sh
xcodebuild -project OpalineTV.xcodeproj -scheme OpalineTV \
  -destination 'generic/platform=tvOS' -configuration Release \
  -archivePath build/OpalineTV.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

## TV behavior

Use directional remote input to move focus and Select to open a card. Back/Menu returns through the navigation stack and AVKit's playback controls. Home, Search, Subscriptions, Library, and Settings have separate navigation stacks. Sign-in displays a verification URL, QR code, and device code to complete on another device; anonymous browsing is available. Account-only lists offer sign-in while signed out.

Playback uses the native AVKit transport bar, with quality, dubbed audio, external captions, SponsorBlock, previous/next, and channel actions. Quality menus reflect the stream's decodable formats; hardware model alone does not guarantee 4K playback. Playlist playback continues through its queue. Suggested autoplay presents a cancellable five-second prompt. Captions load through the existing VTT/XML service and appear in a noninteractive overlay.

Search loads results automatically after a short typing pause. Suggestions occupy a compact row above the results and do not interrupt loading or pagination.

Settings cover account, language/region, appearance, autoplay, playback sources, quality, preferred audio/captions, SponsorBlock categories, and the solver server. New TV-specific strings currently fall back to English when a translation is unavailable.

Shorts, comments, offline downloads, the Open In share extension, phone gestures, notifications, and background audio are outside this first TV release. The TV target does not embed the iOS extension. Static Top Shelf artwork is included; there is no dynamic Top Shelf extension.

## Playback sources and quality

Settings → Playback sources enables/disables each delivery and changes its selection order with Move up/Move down. Existing saved orders and enabled selections are preserved. Signed-in TV SABR is excluded in guest mode. Changes apply to the next playback.

The TV registry composes shared native HLS, MP4 byte ranges, SABR, experimental WebM VP9 and progressive fallback sources. Selection checks enabled sources one at a time in saved order, stopping when one prepares the selected resolution at its best available frame rate. Lower tiers are retained until every source falls short, then ranked by resolution, frame rate, delivery and source order. Each metadata probe has a ten-second deadline; unknown tiers remain last-resort candidates. Recovery refreshes once and then checks remaining target tiers and unvisited sources before lowering resolution. Automatic dubbing follows the shared quality-first policy.

1440p and 2160p preferences appear when AV1 or supplemental VP9 hardware support is available; each source still filters actual playable formats. Auto retains its 1080p cap. VP9 delivery currently requires tvOS 26.2 or later and a positive hardware capability check. Apple TV HD and older systems retain compatible fallback paths.

WebM remains disabled by default. It remuxes supported 8-bit SDR profile-0 VP9 with AAC audio into generated HLS, without software decoding or transcoding. Physical Apple TV validation is still required for sustained native VP9/WebM playback, seeking, A/V sync, and recovery. See [the playback support matrix](playback-support-matrix.md).

## Storage and code sharing

Settings → Accounts supports adding YouTube accounts with the device-code flow, switching saved accounts, renaming and removing them, and guest browsing. Adding an account uses an isolated OAuth client; cancelling or failing sign-in keeps the current account. Removing the active account enters guest mode without removing other saved accounts.

Saved credentials and the active selection use a tvOS-only Keychain vault. The previous single-account credential migrates on first launch. Settings use UserDefaults; recent searches and bounded watch progress use separate keys for each saved account and guest mode. Switching resets the queue, account caches and sync state, discards late API/OAuth responses, and rebuilds the TV screens. These local histories remain subject to tvOS storage eviction. Signed-in history sync uses the existing YouTube services. Image disk cache is limited to 64 MiB and feed cache to 16 MiB on tvOS. Cache directories can disappear between sessions and are recreated on writes. Streaming buffers and servers are released when playback ends; no offline download store is compiled into the TV target.

The two projects are independent: `Opaline.xcodeproj` contains only the upstream iOS app and extension, while `OpalineTV.xcodeproj` contains only the TV app and tests. The iOS source, extension, project and local-config template match the integrated `main` baseline `2c123de7765a5f326e8d75bd82b54c0c8e614361` exactly. The original upstream reference remains available in Git history. Local signing overrides remain in the ignored `Config/Local.xcconfig`.

The TV project references 190 unchanged Swift files under **TV Shared Sources**. It does not copy the shared core or generate patched source during builds. New files under `OpalineTV` and `OpalineTVTests` are synchronized with their respective targets. Shared source membership is explicit, so upstream UI files and new iOS features cannot accidentally enter the TV build.

TV-only code is organized as follows:

| Directory | Responsibility |
| --- | --- |
| `OpalineTV/Accounts` | Account UI, Keychain vault, OAuth client/polling, session boundary, scoped history/progress and sync, account-aware transport |
| `OpalineTV/Platform` | Service composition, TV network/AV1 behavior, localization table lookup, safe collection access and optional offline-library adapters |
| `OpalineTV/Playback` | Online playback facade, TV source registry and settings, stale-response protection and quality preferences |
| `OpalineTV/Search` | Search result model/parser with channel and playlist results |
| `OpalineTV/Storage` | Disposable TV disk caches and bounded cache eviction |

Small adapters allow the stock playback queue, subtitle and SponsorBlock services to compile unchanged: TV supplies the collection helper that upstream defines in a player view controller, and returns no local downloads so those services follow their normal online paths. Where an upstream concrete type cannot be extended safely, the TV project excludes that file and compiles its explicit TV implementation instead. Review upstream changes to these replaced files when updating TV; the rest of the shared core is reused directly.

TV strings live in `OpalineTV/en.lproj/TV.strings` and `TVAccounts.strings`; upstream `Localizable.strings` and translations remain unchanged and are referenced as resources.

Run the stock-boundary check before committing:

```sh
python3 scripts/check-ios-stock.py
```

The baseline is pinned in `Config/TV-Upstream.json`. The check compares tracked files and rejects unexpected files inside the iOS directories. CI runs the same check before building TV. To compare against another local upstream ref, use `--baseline main`. When intentionally updating upstream, restore the protected paths from the new upstream commit, update the pinned commit, review TV replacements and source membership, then build iOS and TV and run TV fixtures.

The `Build Apple TV` workflow builds Debug/Release simulator configurations, runs fixtures, and uploads an unsigned Release archive. Existing iOS release publishing remains separate.

## Device acceptance checks

Before distributing, verify on physical Apple TV HD and Apple TV 4K with both touch-surface and clickpad remotes:

- Sign-in success, code expiry/retry, cancellation while adding another account, switching two accounts, guest mode, removing active/inactive accounts, and relaunch with the selection preserved.
- Confirm each account’s subscriptions, playlists, search history, and watch positions stay separate, including switches during pending network responses.
- Every tab and menu using remote input only; search keyboard/suggestions/filters; channel and playlist navigation; paging, retry, and focus restoration after playback.
- Live and on-demand playback; seek/resume; paused and playing quality/audio switches; external subtitle timing after seeks; codec fallback and unavailable videos.
- Playlist boundaries, queue continuation, previous/next, suggested autoplay cancellation, and SponsorBlock auto/manual skip behavior.
- Network interruption and recovery, leaving the player during resolution, cache eviction, and relaunch without cached files.

Simulator fixtures do not certify real YouTube authentication, stream availability, hardware decoding, or physical remote behavior. Those require the device checks above.
