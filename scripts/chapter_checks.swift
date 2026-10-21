// Compiled with the shipping sources by check_chapters.sh. Only unrelated app dependencies
// (UIKit-owned video/channel types, locale preferences and the client composition root) are stubs.

struct Video: Codable, Equatable {
    let id: String
}
struct ChannelInfo: Codable { let id: String }
enum LikeStatus: String, Codable { case like, dislike, indifferent }
protocol LocalePreferences { var hl: String { get }; var gl: String { get } }
struct DefaultLocalePreferences: LocalePreferences { let hl = "en"; let gl = "US" }
enum AppLog { static func innertube(_ text: String) {} }
final class InnertubeClient {
    let api: APIClient
    let baseURL = "https://www.youtube.com/youtubei/v1"
    var webContext: [String: Any] { InnertubeContexts.web }
    init(transport: HTTPTransport) { api = APIClient(transport: transport) }
}

private var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
func fixtureJSON(_ path: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
}
func playerBar(_ chapters: [[String: Any]], legacy: Bool = false) -> [String: Any] {
    let bar: [String: Any] = legacy
        ? ["chapteredPlayerBarRenderer": ["chapters": chapters]]
        : ["multiMarkersPlayerBarRenderer": ["markersMap": [["value": ["chapters": chapters]]]]]
    return ["playerOverlays": ["playerOverlayRenderer": ["decoratedPlayerBarRenderer": [
        "decoratedPlayerBarRenderer": ["playerBar": bar]
    ]]]]
}
func renderer(_ start: Any, _ title: String = "Title") -> [String: Any] {
    ["chapterRenderer": ["timeRangeStartMillis": start, "title": ["simpleText": title]]]
}
func panel(_ entries: [[String: Any]]) -> [String: Any] {
    ["engagementPanels": [["engagementPanelSectionListRenderer": ["content": [
        "macroMarkersListRenderer": ["contents": entries.map { ["macroMarkersListItemRenderer": $0] }]
    ]]]]]
}
func page() -> WatchPage {
    WatchPage(video: Video(id: "LGA4ZFr-hfo"), description: "Account description",
        channelInfo: ChannelInfo(id: "channel"), subscribeButtonText: "Subscribed", isSubscribed: true,
        relatedVideos: [Video(id: "related")], likeCount: "16K", likeStatus: .like,
        commentCount: "722", nextVideo: Video(id: "next"), playlistTitle: "Private playlist",
        playlistVideos: [Video(id: "queue")], queueContinuation: "next-page", shuffleParams: "shuffle")
}

final class ChapterFixtureTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var response: Result<HTTPResponse, Error>
    var deferred = false
    var pending: (() -> Void)?
    init(json: [String: Any]) throws {
        response = .success(HTTPResponse(status: 200, headers: [:],
            data: try JSONSerialization.data(withJSONObject: json)))
    }
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests.append(request)
        if deferred { pending = { completion(self.response) } }
        else { completion(response) }
    }
}

func parserChecks(_ fixture: [String: Any]) throws -> [VideoChapter] {
    let chapters = VideoChapterParser.parse(fixture)
    check(chapters.map(\.startTime) == [0, 139, 302, 405, 708], "Live fixture timestamps")
    check(chapters.map(\.title) == ["Intro", "How does compression work?", "It's pronounced 'gif'",
        "Where did it go?", "Credits"], "Live fixture titles")
    check(VideoChapterParser.parse([:]).isEmpty, "No chapters")
    let dirty = playerBar([renderer(2000, " Second "), renderer(0, "First"),
        renderer(0, "Duplicate"), renderer(-1), renderer("nan"), renderer("inf"),
        renderer(true), renderer("1000", "  "), ["chapterRenderer": [:]]])
    check(VideoChapterParser.parse(dirty) == [VideoChapter(title: "First", startTime: 0),
        VideoChapter(title: "Second", startTime: 2)], "Invalid chapters rejected, sorted and deduplicated")
    check(VideoChapterParser.parse(playerBar([renderer(0)], legacy: true)).count == 1, "Legacy bar")
    let fallback = panel([
        ["title": ["runs": [["text": "One ", "bold": true], ["text": "chapter"]]],
         "timeDescription": ["simpleText": "1:02:03"]],
        ["title": ["simpleText": "Endpoint"], "onTap": ["watchEndpoint": ["startTimeSeconds": "139"]]],
        ["title": ["simpleText": "Invalid time"], "timeDescription": ["simpleText": "1:99"]],
        ["title": ["simpleText": "Negative"], "onTap": ["watchEndpoint": ["startTimeSeconds": -2]]]
    ])
    check(VideoChapterParser.parse(fallback) == [VideoChapter(title: "Endpoint", startTime: 139),
        VideoChapter(title: "One chapter", startTime: 3723)], "Engagement-panel fallback")
    var combined = fixture
    combined["engagementPanels"] = fallback["engagementPanels"]
    check(VideoChapterParser.parse(combined) == chapters, "Player bar has priority over duplicate panels")
    let irrelevant = ["relatedVideos": [playerBar([renderer(0)])]]
    check(VideoChapterParser.parse(irrelevant).isEmpty, "Do not extract chapters from unrelated videos")
    return chapters
}

func codingChecks(_ chapters: [VideoChapter]) throws {
    var original = page()
    original.chapters = chapters
    original.servedOffline = true
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WatchPage.self, from: data)
    check(decoded.chapters == chapters, "Saved chapters round-trip")
    check(!decoded.servedOffline, "Delivery flag remains excluded from storage")
    var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    legacy.removeValue(forKey: "chapters")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    let olderPage = try JSONDecoder().decode(WatchPage.self, from: legacyData)
    check(olderPage.chapters == nil, "Old offline pages remain decodable")
}

func requestChecks(_ fixture: [String: Any], chapters: [VideoChapter]) throws {
    let transport = try ChapterFixtureTransport(json: fixture)
    let client = InnertubeClient(transport: transport)
    var delivered: WatchPage?
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: nil) {
        delivered = try? $0.get()
    }
    check(delivered?.chapters == chapters, "Signed-in TV page receives WEB chapters")
    check(delivered?.isSubscribed == true && delivered?.likeStatus == .like, "Keep account state")
    check(delivered?.description == "Account description", "Do not replace description with WEB metadata")
    check(delivered?.playlistTitle == "Private playlist" && delivered?.playlistVideos?.first?.id == "queue",
          "Keep private playlist and queue")
    check(delivered?.queueContinuation == "next-page" && delivered?.shuffleParams == "shuffle", "Keep pagination")
    check(delivered?.relatedVideos.first?.id == "related", "Keep recommendations")
    let request = transport.requests.last!
    let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
    let context = body["context"] as! [String: Any]
    let web = context["client"] as! [String: Any]
    check(web["clientName"] as? String == "WEB", "Explicit WEB context")
    check(body["videoId"] as? String == "LGA4ZFr-hfo" && body["playlistId"] == nil, "Public video only")
    check(request.headers["Authorization"] == nil && !request.sendsCookies, "No account credentials or cookies")
    check(request.timeout == 8, "Bound optional chapter fetch latency")

    let count = transport.requests.count
    client.completeWatchPage(.success(page()), anonymous: true, cancellationToken: nil) { _ in }
    var enriched = page(); enriched.chapters = chapters
    client.completeWatchPage(.success(enriched), anonymous: false, cancellationToken: nil) { _ in }
    client.completeWatchPage(.failure(APIError.forbidden), anonymous: false, cancellationToken: nil) { _ in }
    check(transport.requests.count == count, "No extra requests for WEB, existing chapters or failures")

    transport.response = .failure(APIError.transport(URLError(.timedOut)))
    delivered = nil
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: nil) {
        delivered = try? $0.get()
    }
    check(delivered?.video.id == "LGA4ZFr-hfo" && delivered?.isSubscribed == true,
          "Optional chapter failure does not fail the watch page")

    transport.response = .success(HTTPResponse(status: 200, headers: [:], data: Data("{}".utf8)))
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: nil) {
        delivered = try? $0.get()
    }
    check(delivered?.chapters == [], "A video without chapters still returns a watch page")
    transport.response = .success(HTTPResponse(status: 200, headers: [:], data: Data("not JSON".utf8)))
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: nil) {
        delivered = try? $0.get()
    }
    check(delivered?.isSubscribed == true, "Malformed optional metadata does not discard account page")
    transport.response = .success(HTTPResponse(status: 403, headers: [:], data: Data("{}".utf8)))
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: nil) {
        delivered = try? $0.get()
    }
    check(delivered?.isSubscribed == true, "Refused optional metadata does not discard account page")

    transport.deferred = true
    let token = CancellationToken()
    var callbacks = 0
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: token) { _ in callbacks += 1 }
    token.cancel()
    transport.pending?()
    check(callbacks == 0, "Ignore stale response after cancellation")
    let priorCount = transport.requests.count
    client.completeWatchPage(.success(page()), anonymous: false, cancellationToken: token) { _ in callbacks += 1 }
    check(transport.requests.count == priorCount && callbacks == 0, "Do not start cancelled chapter work")
}

let fixture = try fixtureJSON(CommandLine.arguments[1])
let chapters = try parserChecks(fixture)
try codingChecks(chapters)
try requestChecks(fixture, chapters: chapters)
print("Chapter checks passed (\(checks) assertions)")

if ProcessInfo.processInfo.environment["OPALINE_CHAPTER_PROBE"] == "1" {
    let client = InnertubeClient(transport: URLSessionTransport())
    let finished = DispatchSemaphore(value: 0)
    var result: Result<[VideoChapter], Error>?
    client.fetchWatchChapters(videoId: "LGA4ZFr-hfo") { result = $0; finished.signal() }
    precondition(finished.wait(timeout: .now() + 15) == .success, "Live chapter request timed out")
    let live = try result!.get()
    precondition(!live.isEmpty, "Known video returned no chapters")
    for chapter in live { print("\(chapter.startTime)s  \(chapter.title)") }
    print("Live WEB chapter request passed")
}
