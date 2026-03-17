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
- sandboxed hosts should enable loopback client/server networking in debug if needed
- all capture data stays on the local machine and the server requires a short-lived auth token
