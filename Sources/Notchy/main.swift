import AppKit
if CommandLine.arguments.contains("--version") { print("Notchy 1.0.0"); exit(0) }
if CommandLine.arguments.contains("--selftest") {
    do { try runSelfTests(); print("All selftests passed"); exit(0) }
    catch { fputs("Selftest failed: \(error)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
