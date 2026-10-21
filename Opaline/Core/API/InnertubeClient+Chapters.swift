import Foundation

extension InnertubeClient {
    /// The WEB watch response supplies chapters even when TV playback needs an account.
    /// This public metadata request carries neither account credentials nor playlist details.
    func fetchWatchChapters(
        videoId: String,
        cancellationToken: CancellationToken? = nil,
        completion: @escaping (Result<[VideoChapter], Error>) -> Void
    ) {
        var body = webContext
        body["videoId"] = videoId
        execute(
            urlString: "\(baseURL)\(InnertubeEndpoint.next)",
            body: body,
            headers: anonHeaders(),
            cancellationToken: cancellationToken,
            sendsCookies: false,
            timeout: 8,
            logTag: "watchChapters(\(videoId))",
            parse: { VideoChapterParser.parse($0) },
            completion: completion
        )
    }

    /// Add missing chapters while preserving account state, queues and recommendations.
    func completeWatchPage(
        _ result: Result<WatchPage, Error>,
        anonymous: Bool,
        cancellationToken: CancellationToken?,
        completion: @escaping (Result<WatchPage, Error>) -> Void
    ) {
        guard cancellationToken?.isCancelled != true else {
            return
        }
        guard !anonymous, case .success(var page) = result,
              page.chapters?.isEmpty != false else {
            completion(result)
            return
        }
        fetchWatchChapters(
            videoId: page.video.id, cancellationToken: cancellationToken
        ) { chapters in
            guard cancellationToken?.isCancelled != true else {
                return
            }
            if case .success(let chapters) = chapters { page.chapters = chapters }
            completion(.success(page))
        }
    }
}
