import Cocoa

let bundleID = Bundle.main.bundleIdentifier ?? "tech.xvanturing.SwitchProxy"

// Single instance: if another copy is already running, ask it to show its
// manager window ("恢复显示") and exit this one.
let myPID = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != myPID }
if let other = others.first {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("\(bundleID).showManager"),
        object: nil, userInfo: nil, deliverImmediately: true)
    other.activate(options: [])
    usleep(200_000) // give the notification a moment to be delivered before exiting
    exit(0)
}

// Menu-bar-only app: no Dock icon, no main menu bar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
