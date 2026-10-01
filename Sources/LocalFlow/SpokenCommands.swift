import Foundation

/// Voice commands recognised inside a dictation. Commands only count when they stand alone as a sentence
/// ("Hello there. New line. How are you?"), so "add a new line to the invoice" is left alone.
enum SpokenCommands {
    struct Part {
        let text: String
        let separatorAfter: String
    }

    /// True when the whole take is just "scratch that" (undoes the previous paste).
    static func isScratchThat(_ text: String) -> Bool {
        let normalised = text.lowercased().filter { $0.isLetter || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        return normalised == "scratch that"
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?,]\s))(new paragraph|new line)[.,!?]?(?:\s+|$)"#,
        options: [.caseInsensitive]
    )

    /// Splits text at "new line" / "new paragraph" commands so each piece can be cleaned separately.
    static func split(_ text: String) -> [Part] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [Part(text: text, separatorAfter: "")] }

        var parts: [Part] = []
        var cursor = 0
        for match in matches {
            let segment = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let command = ns.substring(with: match.range(at: 1)).lowercased()
            parts.append(Part(text: trimSegment(segment), separatorAfter: command == "new paragraph" ? "\n\n" : "\n"))
            cursor = match.range.location + match.range.length
        }
        parts.append(Part(text: trimSegment(ns.substring(from: cursor)), separatorAfter: ""))
        return parts
    }

    private static func trimSegment(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
