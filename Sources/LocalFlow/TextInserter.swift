import AppKit
import CoreGraphics

/// Pastes text into the focused app: stash the pasteboard, set our text, fire Cmd+V, then restore.
/// Needs Accessibility permission to post the key event.
enum TextInserter {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Cmd+Z in the focused app; used by the "scratch that" voice command to undo the previous paste.
    static func undo() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: keyDown) // 'z'
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transientType) // hint to clipboard managers to skip this entry

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        // Give the target app time to read the pasteboard before we put the old contents back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !saved.isEmpty else { return }
            pb.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
        }
    }
}
