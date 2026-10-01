import AppKit
import Foundation

/// Whole-take voice phrases that start a Spotify track instead of pasting text.
/// Add a line to `all` to teach LocalFlow another one.
enum MusicCommands {
    struct Command {
        let phrases: [String]   // normalised: lowercase, no punctuation or apostrophes
        let trackID: String
        let title: String
    }

    static let all: [Command] = [
        Command(
            phrases: ["wake up daddys home", "wake up daddy is home", "wake up daddies home"],
            trackID: "39shmbIHICJ2Wxnk1fPSdz",
            title: "Should I Stay or Should I Go"
        ),
        Command(
            phrases: ["its time to lock in", "it is time to lock in", "time to lock in"],
            trackID: "22L7bfCiAkJo5xGSQgmiIO",
            title: "All of the Lights"
        ),
    ]

    private static let leadingFiller: Set<String> = ["right", "okay", "ok", "hey", "so", "alright"]

    static func match(_ text: String) -> Command? {
        var cleaned = text.lowercased()
        cleaned = cleaned.replacingOccurrences(of: "'", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\u{2019}", with: "")
        var letters = ""
        for ch in cleaned { letters.append(ch.isLetter ? ch : " ") }
        var words: [String] = letters.split(separator: " ").map { String($0) }
        while let first = words.first, leadingFiller.contains(first) { words.removeFirst() }
        let normalised = words.joined(separator: " ")
        return all.first { $0.phrases.contains(normalised) }
    }

    /// Plays the track in the Spotify desktop app. Falls back to just opening it if scripting is refused.
    @MainActor
    static func play(_ command: Command) {
        let uri = "spotify:track:\(command.trackID)"
        let source = "tell application \"Spotify\" to play track \"\(uri)\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Log.write("spotify play failed (\(error[NSAppleScript.errorMessage] ?? "unknown")); opening URI instead")
            if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
        } else {
            Log.write("spotify: playing \(command.title)")
        }
    }
}
