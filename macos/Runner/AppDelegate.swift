import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Disable the system "double-click the title bar to zoom" action for
    // this app only: with a hidden title bar, double clicks anywhere in
    // the top strip (tabs, pin button) would otherwise maximize the window.
    UserDefaults.standard.register(defaults: ["AppleActionOnDoubleClick": "None"])
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
