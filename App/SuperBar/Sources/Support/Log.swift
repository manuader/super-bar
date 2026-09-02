import os

/// Unified logging. `notice` lines (show/hide/hot key) are persisted and can be
/// read with `/usr/bin/log show --last 5m --predicate 'subsystem == "com.manuader.SuperBar"'`
/// (zsh shadows `log` with a builtin); `debug` lines (every key press, query)
/// only appear in `/usr/bin/log stream --debug`.
enum Log {
    static let palette = Logger(subsystem: "com.manuader.SuperBar", category: "palette")
    static let menus = Logger(subsystem: "com.manuader.SuperBar", category: "menus")
    static let hotkey = Logger(subsystem: "com.manuader.SuperBar", category: "hotkey")
    static let files = Logger(subsystem: "com.manuader.SuperBar", category: "files")
}
