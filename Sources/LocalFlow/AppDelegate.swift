import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "LocalFlow Enabled", action: nil, keyEquivalent: "")
    private let cleanupItem = NSMenuItem(title: "Clean up dictation (LLM)", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")

    private let cleanHotkey = HotkeyMonitor.rightOption()
    private let rawHotkey = HotkeyMonitor.rightCommand()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner()
    private let overlay = OverlayPill()
    private let history = HistoryStore()

    private var isEnabled = true
    private var isRecording = false
    private var isStopping = false
    private var cleanThisTake = true
    private var modelReady = false
    private var cleanerReady = false
    private var hotkeysReady = false
    private var hotkeyTimer: Timer?

    /// Captured when the hotkey goes down, while the target app is still frontmost.
    private var takeStyle: DictationStyle = .standard
    private var takeAppName = ""
    private var lastPaste: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder.preferredDeviceUID = UserDefaults.standard.string(forKey: "micUID")
        setUpMenu()
        overlay.levelProvider = { [recorder] in recorder.level }
        requestPermissions()
        Log.write("start: accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess()) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (mic: 3=authorized) loginItem=\(SMAppService.mainApp.status.rawValue)")
        loadModels()
        startHotkeysWhenAllowed()
    }

    // MARK: Menu

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        enabledItem.action = #selector(toggleEnabled)
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)

        cleanupItem.action = #selector(toggleCleanup)
        cleanupItem.target = self
        cleanupItem.state = .on
        menu.addItem(cleanupItem)

        loginItem.action = #selector(toggleLaunchAtLogin)
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        micItem.submenu = NSMenu()
        menu.addItem(micItem)
        rebuildMicMenu()

        menu.addItem(.separator())
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)
        rebuildHistoryMenu()

        let dictItem = NSMenuItem(title: "Edit Personal Dictionary…", action: #selector(openDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)
        let privItem = NSMenuItem(title: "Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
        privItem.target = self
        menu.addItem(privItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Refresh the microphone list each time the menu opens, so newly plugged-in devices show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu { rebuildMicMenu() }
    }

    private func setIcon(recording: Bool) {
        let name = !isEnabled ? "mic.slash" : (recording ? "mic.fill" : "mic")
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "LocalFlow")
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
    }

    private func rebuildMicMenu() {
        guard let submenu = micItem.submenu else { return }
        submenu.removeAllItems()
        let devices = AudioDevices.inputDevices()
        let selected = UserDefaults.standard.string(forKey: "micUID")
        let defaultDevice = devices.first { $0.uid == AudioDevices.defaultInputUID() }

        func add(_ title: String, uid: String, on: Bool) {
            let item = NSMenuItem(title: title, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = uid
            item.state = on ? .on : .off
            submenu.addItem(item)
        }

        var defaultTitle = "System Default"
        if let d = defaultDevice { defaultTitle += " (\(d.name)\(d.isBluetooth ? " — Bluetooth, low quality" : ""))" }
        add(defaultTitle, uid: "", on: selected == nil)
        submenu.addItem(.separator())
        for d in devices {
            add(d.name + (d.isBluetooth ? " — Bluetooth, low quality" : ""), uid: d.uid, on: selected == d.uid)
        }
        if let selected, !devices.contains(where: { $0.uid == selected }) {
            let missing = NSMenuItem(title: "Chosen mic not connected — using default", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            submenu.addItem(.separator())
            submenu.addItem(missing)
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        if uid.isEmpty {
            UserDefaults.standard.removeObject(forKey: "micUID")
            recorder.preferredDeviceUID = nil
        } else {
            UserDefaults.standard.set(uid, forKey: "micUID")
            recorder.preferredDeviceUID = uid
        }
        Log.write("microphone set to \(uid.isEmpty ? "system default" : sender.title)")
        rebuildMicMenu()
    }

    private func rebuildHistoryMenu() {
        guard let submenu = historyItem.submenu else { return }
        submenu.removeAllItems()
        let shown = history.entries.prefix(10)
        if shown.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for entry in shown {
            let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            let title = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
            let item = NSMenuItem(title: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = "\(entry.app) — click to copy"
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearHistory() {
        history.clear()
        rebuildHistoryMenu()
    }

    /// Off = hotkeys ignored and both models unloaded (frees ~2 GB). On = reload from the local cache.
    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enabledItem.state = isEnabled ? .on : .off
        setIcon(recording: false)
        if isEnabled {
            Log.write("enabled")
            loadModels()
        } else {
            Log.write("disabled, unloading models")
            modelReady = false
            cleanerReady = false
            setStatus("Off — models unloaded")
            Task {
                await transcriber.unload()
                await cleaner.unload()
            }
        }
    }

    @objc private func toggleCleanup() {
        cleanupItem.state = cleanupItem.state == .on ? .off : .on
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Log.write("launch at login change failed: \(error)")
        }
        loginItem.state = service.status == .enabled ? .on : .off
        Log.write("launch at login status=\(service.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func openDictionary() {
        _ = PersonalDictionary.terms() // creates the file on first use
        NSWorkspace.shared.open(PersonalDictionary.url)
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    // MARK: Permissions + hotkeys

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        CGRequestListenEventAccess()
    }

    /// The event taps only work once Input Monitoring is granted, so keep retrying until they do.
    private func startHotkeysWhenAllowed() {
        cleanHotkey.onPress = { [weak self] in self?.beginDictation(clean: true) }
        cleanHotkey.onRelease = { [weak self] in self?.endDictation() }
        rawHotkey.onPress = { [weak self] in self?.beginDictation(clean: false) }
        rawHotkey.onRelease = { [weak self] in self?.endDictation() }

        if cleanHotkey.start() && rawHotkey.start() {
            Log.write("hotkey taps created")
            hotkeysReady = true
            updateReadyStatus()
            return
        }
        Log.write("hotkey tap FAILED (Input Monitoring not granted to this build?)")
        setStatus("Grant Input Monitoring + Accessibility, then wait…")
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.cleanHotkey.start() && self.rawHotkey.start() {
                    Log.write("hotkey taps created on retry")
                    self.hotkeysReady = true
                    timer.invalidate()
                    self.updateReadyStatus()
                }
            }
        }
    }

    // MARK: Models

    private func loadModels() {
        setStatus("Loading speech model…")
        Task {
            do {
                try await transcriber.load()
                guard isEnabled else { await transcriber.unload(); return }
                modelReady = true
                Log.write("speech model ready")
                updateReadyStatus()
            } catch {
                setStatus("Speech model failed: \(error.localizedDescription)")
                Log.write("speech model load failed: \(error)")
                return
            }
            // Cleanup model loads second; dictation works (raw) while it downloads/warms up.
            do {
                try await cleaner.load()
                guard isEnabled else { await cleaner.unload(); return }
                cleanerReady = true
                Log.write("cleanup model ready")
                updateReadyStatus()
            } catch {
                Log.write("cleanup model load failed: \(error)")
                setStatus("Ready (raw only — cleanup model failed)")
            }
        }
    }

    private func updateReadyStatus() {
        guard modelReady, hotkeysReady else { return }
        setStatus(cleanerReady
            ? "Ready — Right ⌥ cleaned, Right ⌘ raw"
            : "Ready (raw) — cleanup model loading…")
    }

    // MARK: Dictation

    private func beginDictation(clean: Bool) {
        Log.write("hotkey down clean=\(clean) (modelReady=\(modelReady))")
        guard isEnabled, modelReady, !isRecording else { return }
        do {
            try recorder.start()
            isRecording = true
            cleanThisTake = clean && cleanupItem.state == .on
            let front = NSWorkspace.shared.frontmostApplication
            takeStyle = DictationStyle.detect(bundleID: front?.bundleIdentifier)
            takeAppName = front?.localizedName ?? "Unknown"
            setIcon(recording: true)
            overlay.show(.listening(raw: !cleanThisTake))
        } catch {
            Log.write("record failed: \(error)")
            overlay.show(.message("Mic error"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.overlay.hide() }
        }
    }

    private func endDictation() {
        Log.write("hotkey up (recording=\(isRecording))")
        guard isRecording, !isStopping else { return }
        isStopping = true
        // Keep recording briefly after release so the last word isn't clipped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finishDictation() }
    }

    private func finishDictation() {
        isStopping = false
        isRecording = false
        setIcon(recording: false)
        let samples = recorder.stop()
        let wantsCleanup = cleanThisTake && cleanerReady
        let style = takeStyle
        let appName = takeAppName

        // Ignore accidental taps (< 0.3 s).
        guard samples.count > 4800 else { overlay.hide(); return }
        overlay.show(.transcribing)

        Task {
            let started = ContinuousClock.now
            do {
                let raw = try await transcriber.transcribe(samples)
                Log.write("\(samples.count / 16) ms audio in \(appName) [\(style.rawValue)] -> \"\(raw)\" in \(started.duration(to: .now))")

                // "Scratch that" on its own undoes the previous paste (if it was recent).
                if SpokenCommands.isScratchThat(raw) {
                    overlay.hide()
                    if let last = lastPaste, Date().timeIntervalSince(last) < 120 {
                        TextInserter.undo()
                        lastPaste = nil
                        Log.write("scratch that: undid previous paste")
                    }
                    return
                }

                // Whole-take music phrases ("wake up, daddy's home") start a Spotify track instead of pasting.
                if let music = MusicCommands.match(raw) {
                    overlay.show(.message("♪ \(music.title)"))
                    MusicCommands.play(music)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.overlay.hide() }
                    return
                }

                // Split at "new line"/"new paragraph", clean each piece, then stitch back together.
                var output = ""
                for part in SpokenCommands.split(raw) {
                    var piece = part.text
                    if wantsCleanup, style != .literal, !piece.isEmpty {
                        overlay.show(.cleaning)
                        piece = await cleaner.clean(piece, dictionary: PersonalDictionary.terms(), style: style)
                    }
                    output += PersonalDictionary.apply(to: piece) + part.separatorAfter
                }
                let text = style.finalise(output)

                overlay.hide()
                Log.write("total \(started.duration(to: .now)) -> \"\(text)\"")
                guard !text.isEmpty else { return }
                TextInserter.paste(text)
                lastPaste = Date()
                history.add(HistoryEntry(date: Date(), app: appName, raw: raw, text: text))
                rebuildHistoryMenu()
            } catch {
                Log.write("transcribe failed: \(error)")
                overlay.hide()
            }
        }
    }
}
