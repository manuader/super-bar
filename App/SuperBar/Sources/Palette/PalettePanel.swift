import AppKit

/// Non-activating floating panel: the target app stays frontmost while the
/// palette has keyboard focus.
final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 480, height: 160)
        maxSize = NSSize(width: 1400, height: 2000)
        titleVisibility = .hidden
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            Log.palette.debug("keyDown code=\(event.keyCode) chars=\(event.characters ?? "", privacy: .public) mods=\(event.modifierFlags.rawValue) key=\(self.isKeyWindow) firstResponder=\(String(describing: type(of: self.firstResponder)), privacy: .public)")
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
