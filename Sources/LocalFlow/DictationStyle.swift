import Foundation

/// How dictation should read in the app you're typing into, picked from the frontmost app's bundle id.
enum DictationStyle: String {
    case standard, chat, email, literal

    static func detect(bundleID: String?) -> DictationStyle {
        guard let id = bundleID?.lowercased() else { return .standard }
        if literalApps.contains(id) { return .literal }
        if chatApps.contains(id) { return .chat }
        if emailApps.contains(id) { return .email }
        return .standard
    }

    /// Extra instruction appended to the cleanup prompt. `literal` skips the LLM entirely.
    var promptNote: String? {
        switch self {
        case .chat:
            return "This is a casual chat message: keep it short and informal, keep contractions, and do not make the wording more formal."
        case .email:
            return "This is an email: use complete, well-punctuated sentences in a polite, professional tone without changing the meaning."
        case .standard, .literal:
            return nil
        }
    }

    /// Chat messages read oddly with a full stop on a single short sentence.
    func finalise(_ text: String) -> String {
        guard self == .chat else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return text }
        let body = trimmed.dropLast()
        if body.contains(where: { ".!?\n".contains($0) }) { return text }
        return String(body)
    }

    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.mobilesms", "net.whatsapp.whatsapp", "com.hnc.discord",
        "ru.keepcoder.telegram", "org.whispersystems.signal-desktop", "com.microsoft.teams2",
        "com.anthropic.claudefordesktop", "com.openai.chat",
    ]
    private static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron",
    ]
    private static let literalApps: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
        "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.xcode", "com.jetbrains.intellij",
    ]
}
