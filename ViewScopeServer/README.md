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
.package(url: "https://github.com/wangwanjie/ViewScope.git", from: "1.2.2")
```

Add the `ViewScopeServer` product to your debug target:

```swift
import ViewScopeServer
```

That is enough for the default behavior. Once the library is loaded in a debug build, `ViewScopeServer` automatically starts after the host app finishes launching.

If you want to control the timing manually, disable automatic startup early and call `start()` yourself later:

```swift
import ViewScopeServer

@main
struct DemoApp: App {
    init() {
        ViewScopeInspector.disableAutomaticStart()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    ViewScopeInspector.start()
                }
        }
    }
}
```

If your macOS debug host enables `App Sandbox`, turn `ENABLE_APP_SANDBOX` off for the Debug configuration first. The current discovery path uses `DistributedNotificationCenter`, and the default macOS app sandbox does not allow a regular app to publish those discovery notifications, so the host never appears in `Live Hosts`.

### CocoaPods

```ruby
pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => 'v1.2.2', :configurations => ['Debug']
或者
pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :branch => 'main', :configurations => ['Debug']
```

### Carthage

```ruby
github "wangwanjie/ViewScope" ~> 1.2
```

Then run:

```bash
carthage update --use-xcframeworks --platform macOS
```

## Notes

- keep `ViewScopeServer` in debug-style configurations only
- sandboxed hosts should disable `App Sandbox` for their Debug configuration when using the current discovery flow
- all capture data stays on the local machine and the server requires a short-lived auth token

## Lifecycle

- default behavior: import and link `ViewScopeServer`, then let it auto-start after app launch
- manual behavior: call `ViewScopeInspector.disableAutomaticStart()` early, then call `ViewScopeInspector.start()` when you are ready
- if the host app itself embeds `ViewScopeServer` only for development tooling, remember to opt out of auto-start where exposing the host would be undesirable
