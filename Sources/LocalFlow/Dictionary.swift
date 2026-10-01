import Foundation

/// Personal dictionary: ~/Library/Application Support/LocalFlow/dictionary.txt
///
/// One entry per line. `Term` alone tells the cleanup model how to spell it and also fixes near-misses
/// (one letter off). `Term = alias1, alias2` additionally replaces those exact mishearings.
/// Lines starting with # are ignored.
enum PersonalDictionary {
    struct Entry {
        let term: String
        let aliases: [String]
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.txt")
    }()

    private static let seed = """
    # One entry per line. "Term" fixes near-misses; "Term = mishearing1, mishearing2" replaces those exactly.
    Gaelen = Galen, Dalen, Gaylen, Gaelin
    LocalFlow = Local Flow
    The Home Insurer
    THI

    """

    static func entries() -> [Entry] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            return Entry(term: parts[0], aliases: aliases)
        }
    }

    static func terms() -> [String] { entries().map(\.term) }

    /// Deterministic fix-up applied to the final text (cleaned or raw): exact aliases, then one-letter-off single words.
    static func apply(to text: String) -> String {
        let entries = entries()
        var result = text

        for entry in entries {
            for alias in entry.aliases {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: alias) + "\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.term))
            }
        }

        // Fuzzy pass: single-word terms of 5+ letters, words exactly one edit away.
        let singleWordTerms = entries.map(\.term).filter { $0.count >= 5 && !$0.contains(" ") }
        guard !singleWordTerms.isEmpty,
              let wordRegex = try? NSRegularExpression(pattern: "[\\p{L}'’]+") else { return result }
        let matches = wordRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let word = String(result[range])
            guard word.count >= 5 else { continue }
            if let term = singleWordTerms.first(where: { $0.lowercased() != word.lowercased() && editDistance($0.lowercased(), word.lowercased()) == 1 }) {
                result.replaceSubrange(range, with: term)
            }
        }
        return result
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > 1 { return 2 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where j <= b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
