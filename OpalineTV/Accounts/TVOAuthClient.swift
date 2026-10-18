// tvOS specialization; the iOS OAuth client remains upstream-owned.
import Foundation

final class OAuthClient {
    struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let interval: Int
        let clientId: String
        let clientSecret: String
    }
    struct PollConfig {
        let deviceCode: String
        let clientId: String
        let clientSecret: String
        let interval: Int
    }
    static let shared = OAuthClient()
    private let deviceCodeURL = AppURLs.YouTubeOAuth.deviceCode
    let tokenURL = AppURLs.YouTubeOAuth.token
    private let scope =
        "http://gdata.youtube.com " +
        "https://www.googleapis.com/auth/youtube-paid-content"
    private var storedTokens: OAuthTokens?
    var tokens: OAuthTokens? {
        get { TVSessionFence.withLock { storedTokens } }
        set { TVSessionFence.withLock { storedTokens = newValue } }
    }
    let persistsTokens: Bool
    func install(_ tokens: OAuthTokens?) {
        TVSessionFence.withLock {
            TVSessionFence.advance()
            storedTokens = tokens
        }
    }
    var isSignedIn: Bool { tokens != nil }
    var isAnonymous: Bool {
        get {
            tokens == nil && UserDefaults.standard.bool(
                forKey: UserDefaultsKeys.Auth.isAnonymous
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: UserDefaultsKeys.Auth.isAnonymous
            )
        }
    }
    /// A RAW transport (no AuthorizingTransport) — OAuth's own token requests
    /// must never trigger the 401-refresh cross-cut, which would recurse.
    private let transport: HTTPTransport
    init(transport: HTTPTransport = URLSessionTransport(), loadStoredTokens: Bool = true) {
        self.transport = transport
        persistsTokens = loadStoredTokens
        storedTokens = loadStoredTokens ? TVAccountStore.shared.activeAccount?.tokens : nil
    }
}

extension OAuthClient {
    static func match(
        pattern: String,
        in string: String,
        group: Int
    ) -> String? {
        let fullRange = NSRange(string.startIndex..., in: string)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: string, range: fullRange),
              let range = Range(result.range(at: group), in: string)
        else {
            return nil
        }
        return String(string[range])
    }
    func makePostRequest(
        urlString: String,
        body: [String: Any]
    ) -> HTTPRequest? {
        guard let url = URL(string: urlString) else {
            return nil
        }
        return HTTPRequest(
            method: .post,
            url: url,
            headers: [HTTPHeader.contentType: HTTPHeaderValue.contentTypeJSON],
            body: try? JSONSerialization.data(withJSONObject: body)
        )
    }
    func performRequest(
        _ request: HTTPRequest,
        cancellationToken: CancellationToken? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // OAuth endpoints return meaningful bodies on non-2xx (e.g. the polling
        // "authorization_pending" 4xx), so the body is surfaced for any status.
        let generation = TVSessionFence.generation
        transport.send(request, cancellationToken: cancellationToken) { result in
            TVSessionFence.withLock {
                guard generation == TVSessionFence.generation else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let response):
                    completion(.success(response.data))
                }
            }
        }
    }
}

extension OAuthClient {
    func requestDeviceCode(
        completion: @escaping (Result<DeviceCodeResponse, Error>) -> Void
    ) {
        fetchClientCredentials { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (clientId, clientSecret)):
                self.doRequestDeviceCode(
                    clientId: clientId,
                    clientSecret: clientSecret,
                    completion: completion
                )
            }
        }
    }
    private func doRequestDeviceCode(
        clientId: String,
        clientSecret: String,
        completion: @escaping (Result<DeviceCodeResponse, Error>) -> Void
    ) {
        let body: [String: Any] = [
            "client_id": clientId,
            "scope": scope,
            "device_id": UUID().uuidString,
            "device_model": "ytlr::"
        ]
        guard let request = makePostRequest(
            urlString: deviceCodeURL,
            body: body
        ) else {
            return
        }
        performRequest(request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                self.parseDeviceCodeResponse(
                    data: data,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    completion: completion
                )
            }
        }
    }
    private func parseDeviceCodeResponse(
        data: Data,
        clientId: String,
        clientSecret: String,
        completion: @escaping (Result<DeviceCodeResponse, Error>) -> Void
    ) {
        guard let json = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verURL = json["verification_url"] as? String,
              let interval = json["interval"] as? Int
        else {
            let raw = String(data: data, encoding: .utf8) ?? "nil"
            AppLog.auth("requestDeviceCode failed: \(raw)")
            completion(.failure(APIError.decodingFailed))
            return
        }
        let response = DeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verURL,
            interval: interval,
            clientId: clientId,
            clientSecret: clientSecret
        )
        completion(.success(response))
    }
}

extension OAuthClient {
    func validToken(completion: @escaping (Result<String, Error>) -> Void) {
        TVSessionFence.withLock { validTokenInCurrentSession(completion: completion) }
    }
    private func validTokenInCurrentSession(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let tokens else {
            if !isAnonymous {
                NotificationCenter.default.post(
                    name: .authorizationRequired,
                    object: nil
                )
            }
            completion(.failure(APIError.unauthorized))
            return
        }
        if !tokens.isExpired {
            AppLog.auth("using cached token")
            completion(.success(tokens.accessToken))
            return
        }
        doRefresh(tokens: tokens, completion: completion)
    }
    func doRefresh(tokens: OAuthTokens, completion: @escaping (Result<String, Error>) -> Void) {
        TVSessionFence.withLock {
            guard self.tokens?.refreshToken == tokens.refreshToken else { return }
            refreshCurrentAccount(tokens: tokens, completion: completion)
        }
    }
    private func refreshCurrentAccount(
        tokens: OAuthTokens,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let body: [String: Any] = [
            "client_id": tokens.clientId,
            "client_secret": tokens.clientSecret,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ]
        guard let request = makePostRequest(
            urlString: tokenURL,
            body: body
        ) else {
            return
        }
        performRequest(request) { [weak self] result in
            switch result {
            case .failure(let error):
                AppLog.auth(
                    "refresh request failed: \(error.localizedDescription)"
                )
                completion(.failure(error))
            case .success(let data):
                self?.handleRefreshResponse(
                    data: data,
                    tokens: tokens,
                    completion: completion
                )
            }
        }
    }
    private func handleRefreshResponse(
        data: Data,
        tokens: OAuthTokens,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let json = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            AppLog.auth(
                "refresh failed: unparseable response: \(raw.prefix(300))"
            )
            completion(.failure(APIError.decodingFailed))
            return
        }
        guard let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            let code = json["error"] as? String ?? "unknown"
            let detail = json["error_description"] as? String ?? ""
            AppLog.auth("refresh rejected: \(code) \(detail)")
            completion(.failure(APIError.decodingFailed))
            return
        }
        var updated = tokens
        updated.accessToken = accessToken
        updated.expiryDate = Date().addingTimeInterval(
            TimeInterval(expiresIn)
        )
        self.tokens = updated
        saveToKeychain(updated)
        AppLog.auth("token refreshed")
        completion(.success(accessToken))
    }
    func signOut() {
        tokens = nil
        isAnonymous = false
        deleteFromKeychain()
    }
}
