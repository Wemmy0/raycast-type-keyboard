import AppKit
import ApplicationServices

// This helper runs outside Raycast so the destination app keeps keyboard focus.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let eventTag: Int64 = 0x54595045434C4950

final class ClipboardTyper {
    private var characters: [Character] = []
    private var position = 0
    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "Preparing to type…")
    private let progress = NSProgressIndicator()
    private var previousModifiers = CGEventSource.flagsState(.combinedSessionState)
    private var finished = false

    func start() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            finish("Clipboard is empty")
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            finish("Allow Accessibility access, then run Type Clipboard again", success: false)
            return
        }
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            finish("Allow Input Monitoring access, then run Type Clipboard again", success: false)
            return
        }

        characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"))

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let typer = Unmanaged<ClipboardTyper>.fromOpaque(context).takeUnretainedValue()
                typer.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let eventTap else {
            finish("Cannot monitor keyboard. Check Input Monitoring permission", success: false)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            finish("Cannot start keyboard monitoring", success: false)
            return
        }
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        showOverlay()

        // Let Raycast close and allow the launch shortcut's modifiers to be released.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            guard !finished else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] _ in
                typeNextCharacter()
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finish("Typing stopped: keyboard monitoring interrupted", success: false)
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != eventTag else { return }
        if type == .keyDown {
            finish("Cancelled after \(position) of \(characters.count) characters")
        } else if type == .flagsChanged {
            let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
            let newPress = event.flags.intersection(modifiers).subtracting(previousModifiers)
            let capsLockChanged = event.flags.contains(.maskAlphaShift) != previousModifiers.contains(.maskAlphaShift)
            previousModifiers = event.flags
            if !newPress.isEmpty || capsLockChanged {
                finish("Cancelled after \(position) of \(characters.count) characters")
            }
        }
    }

    private func showOverlay() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        label.frame = NSRect(x: 20, y: 65, width: 300, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        background.addSubview(label)
        let hint = NSTextField(labelWithString: "Press any key to cancel")
        hint.frame = NSRect(x: 20, y: 41, width: 300, height: 18)
        hint.textColor = .secondaryLabelColor
        background.addSubview(hint)
        progress.frame = NSRect(x: 20, y: 20, width: 300, height: 8)
        progress.isIndeterminate = false
        progress.maxValue = Double(characters.count)
        background.addSubview(progress)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 170, y: frame.minY + 40))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func typeNextCharacter() {
        guard !finished else { return }
        guard position < characters.count else {
            finish("Typed \(characters.count) characters ✓")
            return
        }
        let character = characters[position]
        let keyCode: CGKeyCode = character == "\n" ? 36 : character == "\t" ? 48 : 0
        let units = Array(String(character).utf16)
        // CGEvent accepts up to 20 UTF-16 units per event.
        let chunks = character == "\n" || character == "\t" ? [[]] : stride(from: 0, to: units.count, by: 20).map {
            Array(units[$0..<min($0 + 20, units.count)])
        }
        for chunk in chunks {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
                    finish("Typing stopped: could not create keyboard event", success: false)
                    return
                }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: eventTag)
                if !chunk.isEmpty {
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                }
                event.post(tap: .cghidEventTap)
            }
        }
        position += 1
        label.stringValue = "Typing clipboard · \(position) / \(characters.count)"
        progress.doubleValue = Double(position)
    }

    private func finish(_ message: String, success: Bool = true) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        panel?.orderOut(nil)
        // Raycast displays the last stdout line as a HUD for silent scripts.
        print(message)
        exit(success ? 0 : 1)
    }
}

let typer = ClipboardTyper()
DispatchQueue.main.async { typer.start() }
app.run()
