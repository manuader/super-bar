import AppKit
import SwiftUI
import Carbon
import SuperBarKit

/// A keyboard-driven shortcut recorder: click (or press Space/Return) to start
/// recording, then press the combination. Esc cancels, ⌫ clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey
    var onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = { hotKey = $0 }
        view.onRecordingChanged = onRecordingChanged
        view.hotKey = hotKey
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.hotKey = hotKey
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderView, context: Context) -> CGSize? {
        CGSize(width: 160, height: 24)
    }
}

final class RecorderView: NSView {
    var hotKey: HotKey = .default { didSet { needsDisplay = true } }
    var onChange: ((HotKey) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var isRecording = false { didSet { onRecordingChanged?(isRecording); needsDisplay = true } }
    private var pendingFlags: NSEvent.ModifierFlags = []
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text: String
        let color: NSColor
        if isRecording {
            let mods = modifierSymbols(pendingFlags)
            text = mods.isEmpty ? "Type shortcut…" : mods
            color = .secondaryLabelColor
        } else {
            text = hotKey.display
            color = .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    private func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isRecording { stop() } else { start() }
    }

    override func keyDown(with event: NSEvent) {
        if !isRecording {
            if event.keyCode == 49 || event.keyCode == 36 { start(); return }
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    private func start() {
        isRecording = true
        pendingFlags = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .flagsChanged {
                self.pendingFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                self.needsDisplay = true
                return nil
            }
            self.handle(event)
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }                       // Esc
        if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            stop(); return                                               // ⌫ keeps current
        }
        if let key = HotKey(event: event) {
            hotKey = key
            onChange?(key)
            stop()
        } else {
            NSSound.beep()
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stop() }
        return super.resignFirstResponder()
    }
}
