import AppKit
import SuperBarKit

// `SuperBar --check-ax` prints the Accessibility trust state and exits (used by
// the Makefile and by the skills' debugging notes).
if CommandLine.arguments.contains("--check-ax") {
    print(AXMenuSource().isTrusted ? "trusted" : "not trusted")
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
