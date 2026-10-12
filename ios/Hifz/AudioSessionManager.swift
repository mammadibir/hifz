import AVFoundation

/// One place that decides how the app uses audio:
/// reciters play like a music player (with the silent switch on and with the screen locked),
/// and while the voice check is listening the microphone is on and sounds still come out of the speaker.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private let session = AVAudioSession.sharedInstance()

    /// Set the category without activating it, so opening the app does not stop the user's music.
    /// The session becomes active when a reciter actually starts playing.
    func configureForPlayback() {
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
    }

    func activateForRecording() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        if #available(iOS 13.0, *) {
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        try session.setActive(true, options: [])
    }

    func finishRecording() {
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
    }
}
