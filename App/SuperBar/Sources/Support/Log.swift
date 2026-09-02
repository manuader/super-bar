import os

/// Unified logging. `notice` lines (show/hide/hot key) are persisted and can be
/// read with `log show --last 5m --predicate 'subsystem == "com.manuader.SuperBar"'`;
/// `debug` lines (every key press, query) only appear in `log stream --debug`.
enum Log {
    static let palette = Logger(subsystem: "com.manuader.SuperBar", category: "palette")
    static let menus = Logger(subsystem: "com.manuader.SuperBar", category: "menus")
    static let hotkey = Logger(subsystem: "com.manuader.SuperBar", category: "hotkey")
}
