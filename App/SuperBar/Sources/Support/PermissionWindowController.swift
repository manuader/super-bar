import AppKit
import SwiftUI
import SuperBarKit

/// First-run window explaining the Accessibility permission.
@MainActor
final class PermissionWindowController: NSWindowController {
    private unowned let app: AppDelegate
    private var timer: Timer?

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PermissionView(hotKey: app.preferences.hotKey.display, onOpen: { [weak self] in self?.openSettings() }, onQuit: { NSApp.terminate(nil) }))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func openSettings() {
        _ = AXMenuSource.requestTrust()
        NSWorkspace.shared.open(AXMenuSource.accessibilitySettingsURL)
    }

    private func poll() {
        guard app.menuSource.isTrusted else { return }
        timer?.invalidate()
        close()
        app.preferences.didOnboard = true
        app.palette.show()
    }
}

private struct PermissionView: View {
    let hotKey: String
    let onOpen: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 24)
            Text("Welcome to SuperBar")
                .font(.title2.weight(.semibold))
            Text("SuperBar searches the menu bar of the app in front of you. macOS only allows that through the Accessibility API, so it needs your permission once.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 8) {
                Label("Click **Open System Settings**", systemImage: "1.circle.fill")
                Label("Turn on **SuperBar** under Accessibility", systemImage: "2.circle.fill")
                Label("Press **\(hotKey)** in any app", systemImage: "3.circle.fill")
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: 360, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            Spacer()
            HStack {
                Button("Quit", action: onQuit)
                    .keyboardShortcut("q")
                Spacer()
                Button("Open System Settings", action: onOpen)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440, height: 360)
    }
}
