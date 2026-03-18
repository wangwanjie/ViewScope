# ViewScopeServer

`ViewScopeServer` enables AppKit apps to expose live UI snapshots to the `ViewScope` macOS inspector.

## Features

- loopback-only transport with per-session auth token
- local discovery via `DistributedNotificationCenter`
- live hierarchy capture for `NSWindow` and `NSView`
- on-demand detail inspection, screenshots, and highlight overlays
- debug-first runtime guard so release builds stay inert by default

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/wangwanjie/ViewScope.git", from: "1.0.0")
```

Add the `ViewScopeServer` product to your debug target and start it after launch:

```swift
import ViewScopeServer

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ViewScopeInspector.start()
    }
}
```

If your macOS debug host enables `App Sandbox`, turn `ENABLE_APP_SANDBOX` off for the Debug configuration first. `ViewScope 1.0` discovers hosts through `DistributedNotificationCenter`, and the default macOS app sandbox does not allow a regular app to publish those discovery notifications, so the host never appears in `Live Hosts`.

### CocoaPods

```ruby
pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => 'v1.0.0', :configurations => ['Debug']
```

### Carthage

```ruby
github "wangwanjie/ViewScope" ~> 1.0
```

Then run:

```bash
carthage update --use-xcframeworks --platform macOS
```

## Notes

- keep `ViewScopeServer` in debug-style configurations only
- sandboxed hosts should disable `App Sandbox` for their Debug configuration in `ViewScope 1.0`
- all capture data stays on the local machine and the server requires a short-lived auth token
