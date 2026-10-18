import XCTest
@testable import OpalineTV

final class AuthTests: XCTestCase {
    private let config = OAuthClient.PollConfig(deviceCode: "fixture", clientId: "fixture", clientSecret: "fixture", interval: 0)

    func testCancelledPollDoesNotRequestOrComplete() {
        let transport = AuthFixtureTransport()
        let client = OAuthClient(transport: transport, loadStoredTokens: false)
        let cancellation = CancellationToken()
        cancellation.cancel()
        client.pollForToken(config: config, cancellationToken: cancellation) { _ in XCTFail("Cancelled polling completed") }
        XCTAssertEqual(transport.requests, 0)
        XCTAssertNil(client.tokens)
    }

    func testLateSuccessAfterCancellationCannotSignIn() {
        let transport = AuthFixtureTransport()
        let client = OAuthClient(transport: transport, loadStoredTokens: false)
        let cancellation = CancellationToken()
        let requested = expectation(description: "Request received")
        transport.respond = { done in
            cancellation.cancel()
            let json = "{\"access_token\":\"fixture\",\"refresh_token\":\"fixture\",\"expires_in\":3600}"
            done(.success(HTTPResponse(status: 200, headers: [:], data: Data(json.utf8))))
            requested.fulfill()
        }
        client.pollForToken(config: config, cancellationToken: cancellation) { _ in XCTFail("Cancelled success delivered") }
        wait(for: [requested], timeout: 2)
        XCTAssertNil(client.tokens)
    }

    func testExpiredCodeReturnsFailureForRetry() {
        let transport = AuthFixtureTransport()
        let client = OAuthClient(transport: transport, loadStoredTokens: false)
        transport.respond = { done in
            done(.success(HTTPResponse(status: 400, headers: [:], data: Data("{\"error\":\"expired_token\"}".utf8))))
        }
        let expired = expectation(description: "Expired code")
        client.pollForToken(config: config, cancellationToken: CancellationToken()) { result in
            if case .success = result { XCTFail("Expired code authorized") }
            expired.fulfill()
        }
        wait(for: [expired], timeout: 2)
        XCTAssertNil(client.tokens)
    }

    func testNetworkFailureReturnsFailureForRetry() {
        let transport = AuthFixtureTransport()
        let client = OAuthClient(transport: transport, loadStoredTokens: false)
        transport.respond = { done in done(.failure(URLError(.notConnectedToInternet))) }
        let offline = expectation(description: "Offline")
        client.pollForToken(config: config) { result in
            if case .success = result { XCTFail("Offline request authorized") }
            offline.fulfill()
        }
        wait(for: [offline], timeout: 2)
    }
}

private final class AuthFixtureTransport: HTTPTransport {
    var requests = 0
    var respond: (((Result<HTTPResponse, Error>) -> Void) -> Void)?
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests += 1
        respond?(completion)
    }
}
