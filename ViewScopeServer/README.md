# ViewScopeServer

`ViewScopeServer` enables AppKit (macOS) and UIKit (iOS / iPadOS) apps to expose live UI snapshots to the `ViewScope` macOS inspector.

## Features

- loopback-only transport with per-connection authentication (short-lived auth token)
- discovery by port scanning: the host listens on the first free port in `127.0.0.1:47300...47339`
  - macOS hosts additionally broadcast via `DistributedNotificationCenter` (backwards compatible)
  - iOS Simulator hosts share the Mac loopback, so ViewScope finds them directly
  - iOS devices are reached through `usbmuxd` (USB / network pairing), no extra setup on the device
- live hierarchy capture for windows, views and layers (`NSWindow`/`NSView`/`CALayer`, `UIWindow`/`UIView`/`CALayer`)
- on-demand detail inspection, screenshots, highlight overlays and live editing
- console with method arguments, key paths, object references and auto-completion
- debug-first runtime guard so release builds stay inert by default

## Requirements

- macOS 12+ or iOS 13+ (deployment target; building for iOS with Xcode 27 requires raising the app's iOS deployment target to 15.0, which Xcode enforces)
- Swift 6 toolchain

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/wangwanjie/ViewScope.git", from: "1.3.0")
```

Add the `ViewScopeServer` product to your debug target (macOS or iOS):

```swift
import ViewScopeServer
```

That is enough for the default behavior. Once the library is loaded in a debug build, `ViewScopeServer` automatically starts after the host app finishes launching (`NSApplicationDidFinishLaunchingNotification` on macOS, `UIApplicationDidFinishLaunchingNotification` on iOS; if the library is loaded after launch it starts right away).

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

### CocoaPods

```ruby
pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => 'v1.3.0', :configurations => ['Debug']
或者
pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :branch => 'main', :configurations => ['Debug']
```

The podspec supports both `osx` and `ios` platforms and injects `-Wl,-u,_ViewScopeServerBootstrapAnchor` so the auto-start bootstrap is always linked.

### Carthage

```ruby
github "wangwanjie/ViewScope" ~> 1.3
```

Then run:

```bash
carthage update --use-xcframeworks --platform macOS,iOS
```

`ViewScopeServer.xcodeproj` builds one framework target for `macosx`, `iphoneos` and `iphonesimulator`.

## iOS integration

### iOS Simulator

Nothing else is required. The simulator shares the Mac's loopback interface, so ViewScope's port scan finds the app as soon as it is running.

### iOS device

1. Connect the device by USB (or pair it for network debugging in Xcode).
2. Run the Debug build on the device.
3. ViewScope talks to the device through `usbmuxd`, scanning the same port range on the device's loopback interface.

The server only binds `127.0.0.1` on iOS; it is never reachable from the local network. If every port in the range is taken the server logs a message and stays idle.

### Notes for iOS hosts

- `ViewScopeServer` uses only public UIKit APIs for capture; private ivar tracing skips system classes.
- Keep the package/pod in Debug configurations only — the server is inert in Release unless you pass `allowInReleaseBuilds: true` or set `VIEWSCOPE_SERVER_ENABLE_IN_RELEASE=1`.

## macOS sandboxed hosts

If your macOS debug host enables `App Sandbox`, either:

- add the `com.apple.security.network.server` entitlement to the Debug configuration, so ViewScope can discover the host by port scanning; or
- turn `ENABLE_APP_SANDBOX` off for the Debug configuration (the sandbox also blocks `DistributedNotificationCenter` discovery).

## Notes

- keep `ViewScopeServer` in debug-style configurations only
- all capture data stays on the local machine (or the USB-connected device) and every connection must authenticate with the host's token
- discovery probes (`discoveryRequest`, `ping`) never interrupt an authenticated ViewScope session; a new session replaces the old one only after it authenticates

## Lifecycle

- default behavior: import and link `ViewScopeServer`, then let it auto-start after app launch
- manual behavior: call `ViewScopeInspector.disableAutomaticStart()` early, then call `ViewScopeInspector.start()` when you are ready
- if the host app itself embeds `ViewScopeServer` only for development tooling, remember to opt out of auto-start where exposing the host would be undesirable
