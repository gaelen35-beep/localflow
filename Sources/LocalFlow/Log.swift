import Foundation

/// Appends to ~/Library/Logs/LocalFlow.log (and NSLog) so behaviour can be inspected without Xcode.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LocalFlow.log")
    private static let queue = DispatchQueue(label: "localflow.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        NSLog("LocalFlow: %@", message)
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
