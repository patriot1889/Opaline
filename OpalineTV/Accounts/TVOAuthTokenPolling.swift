import Foundation

extension OAuthClient {
    func pollForToken(
        config: PollConfig,
        cancellationToken: CancellationToken? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard cancellationToken?.isCancelled != true else {
            return
        }
        let delay = DispatchTime.now() + .seconds(config.interval)
        DispatchQueue.global().asyncAfter(deadline: delay) { [weak self] in
            self?.exchangeToken(
                config: config, cancellationToken: cancellationToken, completion: completion
            )
        }
    }
    // The cancellation checks bracket the network request and its response.
    // swiftlint:disable:next function_body_length
    private func exchangeToken(
        config: PollConfig,
        cancellationToken: CancellationToken? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard cancellationToken?.isCancelled != true else {
            return
        }
        let body: [String: Any] = [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "code": config.deviceCode,
            "grant_type":
                "http://oauth.net/grant_type/device/1.0"
        ]
        guard let request = makePostRequest(
            urlString: tokenURL,
            body: body
        ) else {
            return
        }
        performRequest(request, cancellationToken: cancellationToken) { [weak self] result in
            guard cancellationToken?.isCancelled != true else {
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                self?.handleExchangeResponse(
                    data: data,
                    config: config,
                    cancellationToken: cancellationToken,
                    completion: completion
                )
            }
        }
    }
    // Keep the OAuth pending/slow-down/success branches together.
    // swiftlint:disable:next function_body_length
    private func handleExchangeResponse(
        data: Data,
        config: PollConfig,
        cancellationToken: CancellationToken? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let json = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any] else {
            completion(.failure(APIError.decodingFailed))
            return
        }
        guard cancellationToken?.isCancelled != true else {
            return
        }
        let errorType = json["error"] as? String
        if let accessToken = json["access_token"] as? String,
           let refreshToken = json["refresh_token"] as? String,
           let expiresIn = json["expires_in"] as? Int {
            saveNewTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresIn: expiresIn,
                config: config
            )
            completion(.success(()))
        } else if errorType == "authorization_pending" {
            pollForToken(
                config: config, cancellationToken: cancellationToken, completion: completion
            )
        } else if errorType == "slow_down" {
            retrySlowDown(
                config: config, cancellationToken: cancellationToken, completion: completion
            )
        } else {
            let raw = String(data: data, encoding: .utf8) ?? "nil"
            AppLog.auth("exchangeToken failed: \(raw)")
            completion(.failure(APIError.decodingFailed))
        }
    }
    private func retrySlowDown(
        config: PollConfig,
        cancellationToken: CancellationToken? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let slower = PollConfig(
            deviceCode: config.deviceCode,
            clientId: config.clientId,
            clientSecret: config.clientSecret,
            interval: config.interval + 5
        )
        pollForToken(
                config: slower, cancellationToken: cancellationToken, completion: completion
            )
    }
    private func saveNewTokens(
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        config: PollConfig
    ) {
        let newTokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: Date().addingTimeInterval(
                TimeInterval(expiresIn)
            ),
            clientId: config.clientId,
            clientSecret: config.clientSecret
        )
        tokens = newTokens
        saveToKeychain(newTokens)
        AppLog.auth("new token obtained")
    }
}
