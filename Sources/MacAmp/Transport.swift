import Foundation

/// What the windows control: the local player or Spotify, whichever is currently playing.
@MainActor
protocol Transport: AnyObject {
    var state: Player.State { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var volume: Float { get set }
    var channelCount: Int { get }
    /// Toggles between playing and paused.
    func pause()
    func stop()
    func seek(to seconds: Double)
}

extension Player: Transport {}
