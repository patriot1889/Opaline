import UIKit
import CoreImage.CIFilterBuiltins

final class TVAuthController: UIViewController {
    var onComplete: (() -> Void)?
    private let client = OAuthClient(loadStoredTokens: false)
    private var cancellation = CancellationToken()
    private let codeLabel = UILabel()
    private let status = UILabel()
    private let qrView = UIImageView()
    private let retry = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TVPalette.background
        let heading = UILabel()
        heading.text = "account.signIn".localized
        heading.font = .systemFont(ofSize: 48, weight: .bold)
        codeLabel.font = .monospacedSystemFont(ofSize: 56, weight: .semibold)
        codeLabel.textAlignment = .center
        status.font = .systemFont(ofSize: 28)
        status.numberOfLines = 3
        status.textAlignment = .center
        qrView.contentMode = .scaleAspectFit
        retry.setTitle("TV.retry".tvLocalized, for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.start() }, for: .primaryActionTriggered)
        let anonymous = UIButton(type: .system)
        anonymous.setTitle(OAuthClient.shared.isSignedIn ? "TV.cancel".tvLocalized : "auth.continueAnonymously".localized, for: .normal)
        anonymous.addAction(UIAction { [weak self] _ in
            self?.cancellation.cancel()
            guard let self else { return }
            if OAuthClient.shared.isSignedIn {
                self.dismiss(animated: true)
            } else {
                do {
                    try TVAccountSession.change { try TVAccountStore.shared.select(nil) }
                    self.onComplete?()
                } catch { self.failed() }
            }
        }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [heading, status, codeLabel, qrView, retry, anonymous])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 1100),
            qrView.widthAnchor.constraint(equalToConstant: 240), qrView.heightAnchor.constraint(equalToConstant: 240),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        start()
    }
    private func start() {
        cancellation.cancel()
        let token = CancellationToken()
        cancellation = token
        retry.isHidden = true
        codeLabel.text = nil
        qrView.image = nil
        status.text = "auth.fetchingCode".localized
        client.requestDeviceCode { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                switch result {
                case .failure: self.failed()
                case .success(let code):
                    self.codeLabel.text = code.userCode
                    self.status.text = String(format: "TV.authInstructions".tvLocalized, code.verificationURL)
                    let filter = CIFilter.qrCodeGenerator()
                    filter.message = Data(code.verificationURL.utf8)
                    if let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) {
                        self.qrView.image = UIImage(ciImage: image)
                    }
                    self.qrView.layer.magnificationFilter = .nearest
                    self.client.pollForToken(config: OAuthClient.PollConfig(
                        deviceCode: code.deviceCode, clientId: code.clientId, clientSecret: code.clientSecret,
                        interval: code.interval
                    ), cancellationToken: token) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self, !token.isCancelled else { return }
                            switch result {
                            case .success:
                                guard let tokens = self.client.tokens else { self.failed(); return }
                                do {
                                    try TVAccountSession.change {
                                        try TVAccountStore.shared.add(tokens: tokens,
                                            name: "YouTube \(TVAccountStore.shared.accounts.count + 1)")
                                    }
                                    TVAccountsController.loadActiveName()
                                    self.onComplete?()
                                } catch { self.failed() }
                            case .failure: self.failed()
                            }
                        }
                    }
                }
            }
        }
    }
    private func failed() {
        status.text = "TV.authFailed".tvLocalized
        retry.isHidden = false
        setNeedsFocusUpdate()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancellation.cancel()
    }
    deinit { cancellation.cancel() }
}
