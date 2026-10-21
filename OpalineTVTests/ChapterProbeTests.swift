import AVFoundation
import XCTest
@testable import OpalineTV

/// Opt-in live diagnostic: OPALINE_CHAPTER_PROBE=1. Ordinary test runs never contact YouTube.
@MainActor
final class ChapterProbeTests: XCTestCase {
    func testLiveChapterSources() async throws {
        guard ProcessInfo.processInfo.environment["OPALINE_CHAPTER_PROBE"] == "1" else {
            throw XCTSkip("Set OPALINE_CHAPTER_PROBE=1 to run the live YouTube chapter probe")
        }
        let videoID = "LGA4ZFr-hfo"
        let transport = ChapterProbeTransport()
        let client = InnertubeClient(transport: transport)
        let token = CancellationToken()
        defer { token.cancel() }
        var report: [String: Any] = ["videoID": videoID, "signedIn": OAuthClient.shared.isSignedIn]
        defer {
            report["responses"] = transport.summaries
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(string: text)
                attachment.name = "Chapter probe LGA4ZFr-hfo"
                attachment.lifetime = .keepAlways
                add(attachment)
                try? data.write(to: URL(fileURLWithPath: "/tmp/opaline-chapter-probe.json"))
                print("CHAPTER_PROBE_REPORT\n" + text)
            }
        }

        let watchDone = expectation(description: "Shared watch-page request")
        var watchResult: Result<WatchPage, Error>?
        client.fetchWatchPage(video: Video(id: videoID), cancellationToken: token) { result in
            DispatchQueue.main.async { watchResult = result; watchDone.fulfill() }
        }
        await fulfillment(of: [watchDone], timeout: 60)
        if let watchResult {
            switch watchResult {
            case .success(let page):
                report["watchPage"] = ["title": page.video.title, "description": page.description ?? "",
                                       "modelHasChapterField": false]
            case .failure(let error):
                report["watchPageError"] = errorSummary(error)
                XCTFail("Shared watch-page request failed: \(errorSummary(error))")
            }
        }

        if OAuthClient.shared.isSignedIn {
            let webDone = expectation(description: "Anonymous WEB comparison")
            client.executeWatchNext(video: Video(id: videoID), token: "", anonymous: true,
                                    cancellationToken: token) { _ in webDone.fulfill() }
            await fulfillment(of: [webDone], timeout: 60)
        }

        // Compare the same /next implementation using the TV context without account credentials.
        let tvDone = expectation(description: "TV-context watch-page request")
        client.executeWatchNext(video: Video(id: videoID), token: "", cancellationToken: token) { _ in tvDone.fulfill() }
        await fulfillment(of: [tvDone], timeout: 60)
        let structuredChapters = transport.summaries.filter { ($0["client"] as? String) == "WEB" }
            .flatMap { $0["chapters"] as? [[String: Any]] ?? [] }
            .filter { $0["startMillis"] != nil }
        XCTAssertFalse(structuredChapters.isEmpty, "Known chaptered video must expose structured chapters in the shared watch request")

        let steps = PlaybackChainSettings.activeSteps()
        report["playbackSteps"] = steps.map(\.id)
        let source = FallbackChainSource(steps: steps, apiClient: client)
        defer { source.releaseResources() }
        let preparedDone = expectation(description: "Actual playback chain preparation")
        var preparedResult: Result<PreparedPlayback, Error>?
        source.loadPlayback(videoId: videoID, cancellation: token) { result in
            DispatchQueue.main.async { preparedResult = result; preparedDone.fulfill() }
        }
        await fulfillment(of: [preparedDone], timeout: 150)
        guard let preparedResult else { report["streamError"] = "Preparation did not finish"; return }
        switch preparedResult {
        case .failure(let error):
            report["streamError"] = errorSummary(error)
            XCTFail("Playback chain could not prepare the stream: \(errorSummary(error))")
        case .success(let prepared):
            report["selectedSource"] = source.name
            report["streamDuration"] = prepared.duration
            let player = AVPlayer(playerItem: prepared.item)
            defer { player.replaceCurrentItem(with: nil) }
            // The resource loader and source stay retained until AVFoundation finishes inspection.
            do {
                let groups = try await prepared.item.asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
                var chapters: [[String: Any]] = []
                for group in groups {
                    var entry: [String: Any] = ["start": group.timeRange.start.seconds,
                                                "duration": group.timeRange.duration.seconds]
                    for item in group.items where item.commonKey == .commonKeyTitle {
                        entry["title"] = try? await item.load(.stringValue)
                    }
                    chapters.append(entry)
                }
                report["streamChapters"] = chapters
                report["streamChapterLocales"] = try await prepared.item.asset.load(.availableChapterLocales).map(\.identifier)
            } catch {
                report["streamMetadataError"] = errorSummary(error)
                XCTFail("Prepared stream metadata could not be read: \(errorSummary(error))")
            }
            if let innertube = source.active as? InnertubeVideoSource, let info = innertube.info {
                var directResults: [[String: Any]] = []
                for (kind, format) in [("video", info.dashVideoFormat), ("audio", info.dashAudioFormat)] {
                    guard let format else { continue }
                    let url = innertube.client.directURL(baseURL: format.url, poToken: nil)
                    let headers = innertube.client.streamHeaders(visitorData: info.visitorData)
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    var result: [String: Any] = ["kind": kind, "itag": format.itag]
                    do {
                        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
                        result["chapterCount"] = groups.count
                        result["chapterLocales"] = try await asset.load(.availableChapterLocales).map(\.identifier)
                        result["playable"] = try await asset.load(.isPlayable)
                    } catch { result["error"] = errorSummary(error) }
                    asset.cancelLoading()
                    directResults.append(result)
                }
                report["directMediaMetadata"] = directResults
            }
            withExtendedLifetime(prepared.resourceLoader) {}
        }
    }

    private func errorSummary(_ error: Error) -> [String: Any] {
        let error = error as NSError
        return ["domain": error.domain, "code": error.code]
    }
}

/// Records only chapter metadata, client names and status; never credentials or signed stream URLs.
private final class ChapterProbeTransport: HTTPTransport {
    private let inner = URLSessionTransport()
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    var summaries: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return records }

    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        inner.send(request, cancellationToken: cancellationToken) { result in
            if case .success(let response) = result,
               let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let context = body?["context"] as? [String: Any]
                let client = context?["client"] as? [String: Any]
                var chapters: [[String: Any]] = []
                var chapterKeys = Set<String>()
                Self.inspect(json, path: "$", chapters: &chapters, keys: &chapterKeys)
                var record: [String: Any] = ["endpoint": request.url.path, "client": client?["clientName"] ?? "unknown",
                                            "httpStatus": response.status, "topLevelKeys": json.keys.sorted(),
                                            "chapterKeys": chapterKeys.sorted(), "chapters": chapters]
                if let status = json["playabilityStatus"] as? [String: Any] {
                    record["playability"] = status["status"]
                    record["reason"] = status["reason"]
                }
                self.lock.lock(); self.records.append(record); self.lock.unlock()
            }
            completion(result)
        }
    }

    private static func text(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return value as? String ?? "" }
        return dict["simpleText"] as? String ?? (dict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private static func inspect(_ value: Any, path: String, chapters: inout [[String: Any]], keys: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                let childPath = path + "." + key
                if key.lowercased().contains("chapter") || key.lowercased().contains("macromarker") { keys.insert(childPath) }
                if let chapter = child as? [String: Any], key == "chapterRenderer" || key == "macroMarkersListItemRenderer" {
                    var entry: [String: Any] = ["path": childPath, "title": text(chapter["title"])]
                    entry["startMillis"] = chapter["timeRangeStartMillis"]
                    entry["timeText"] = text(chapter["timeDescription"])
                    chapters.append(entry)
                }
                inspect(child, path: childPath, chapters: &chapters, keys: &keys)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() { inspect(child, path: "\(path)[\(index)]", chapters: &chapters, keys: &keys) }
        }
    }
}
