import AVFAudio
import Foundation

/// tvOS has no asynchronous activation API. Keep its blocking calls off the
/// main thread and serialize them across player dismissal and reopening.
enum TVPlaybackAudioSession {
    private static let queue = DispatchQueue(label: "OpalineTV.audio-session", qos: .userInitiated)

    static func activate(completion: @escaping (Error?) -> Void) {
        queue.async {
            let error: Error?
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
                error = nil
            } catch let activationError {
                error = activationError
            }
            DispatchQueue.main.async { completion(error) }
        }
    }

    static func deactivate() {
        queue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                AppLog.player("TV audio session deactivation failed: \(error.localizedDescription)")
            }
        }
    }
}
