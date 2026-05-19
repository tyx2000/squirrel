// Purpose: Defines the explicit AppKit entry point and keeps the application delegate alive.

import AppKit

@main
enum SquirrelMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
