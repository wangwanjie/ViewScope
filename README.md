# ViewScope

ViewScope 是一个面向原生 macOS 开发的 UI 调试工具，目标是在 AppKit 项目里提供类似 Lookin / Reveal 的实时层级查看、属性检查、截图预览与节点高亮体验，同时尽量保持集成成本低、数据只在本机流动。

## 特性

- 原生 AppKit 客户端，支持主窗口、状态栏入口、偏好设置与 Sparkle 更新检查
- 自动发现本机 Debug 宿主，使用 `DistributedNotificationCenter` 广播 + `127.0.0.1` TCP 握手通信
- 层级树搜索、属性面板、约束列表、局部截图预览、节点高亮
- 通过 GRDB 记录最近连接宿主与捕获耗时，用于会话历史和性能洞察
- `ViewScopeServer` 同时支持 Swift Package Manager、CocoaPods、Carthage
- 自带 DMG、GitHub Release、Sparkle appcast 脚本，方便继续发布后续版本

## 截图

<p>
  <img src="READMEAssets/main-window.png" alt="ViewScope 主窗口" width="100%" />
</p>
<p>
  <img src="READMEAssets/preferences.png" alt="ViewScope 偏好设置窗口" width="720" />
</p>

## 项目结构

- `ViewScope/`: 主应用工程，使用 SnapKit、GRDB、Sparkle 和本地 `ViewScopeServer` 包
- `ViewScopeServer/`: 宿主侧运行时，包含 SPM 包、CocoaPods podspec、Carthage framework 工程
- `READMEAssets/`: README 截图资源，由测试自动生成
- `scripts/`: DMG、GitHub Release、Sparkle appcast 脚本
- `release-notes/`: 每个版本的发布说明

## 本地开发

要求：

- macOS 11.0+
- Xcode（当前仓库已在本机 Xcode 17C529 环境完成构建与测试）

常用命令：

```bash
xcodebuild \
  -project ViewScope/ViewScope.xcodeproj \
  -scheme ViewScope \
  -destination 'platform=macOS' \
  test

swift test --package-path ViewScopeServer

xcodebuild \
  -project ViewScopeServer/ViewScopeServer.xcodeproj \
  -scheme ViewScopeServer \
  -destination 'generic/platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

## 集成 ViewScopeServer

### Swift Package Manager

```swift
.package(url: "https://github.com/wangwanjie/ViewScope.git", from: "1.0.0")
```

把 `ViewScopeServer` product 加到 Debug 宿主 target，并在启动阶段调用：

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

然后执行：

```bash
carthage update --use-xcframeworks --platform macOS
```

将生成的 `ViewScopeServer.framework` 链接到 Debug 宿主，再调用 `ViewScopeInspector.start()`。

## 使用方式

1. 启动 ViewScope。
2. 运行已集成 `ViewScopeServer` 的 Debug 宿主应用。
3. 在左侧 `Live Hosts` 里选择宿主，ViewScope 会通过 loopback 建立连接。
4. 在层级树中搜索或选中节点，右侧会显示属性、约束和截图预览。
5. 需要时可通过主窗口按钮或状态栏菜单触发刷新和高亮。

## 状态栏设计

ViewScope 会常驻一个 `VS` 状态栏入口：

- 实时显示当前是否已连接宿主
- 直接打开主窗口、刷新当前捕获、开关自动刷新和自动高亮
- 展示最近发现的本机宿主列表，便于快速连接
- 提供偏好设置和手动检查更新入口

## 安全与性能

- 发现和采集数据默认只在本机传输，不依赖远端服务
- 宿主监听地址固定在 `127.0.0.1`，并使用一次性 token 完成握手
- 默认只建议在 Debug 构建里启用 `ViewScopeServer`
- 捕获历史限制为最近 250 条，避免数据库持续膨胀

## 发布

版本号来源：

- 主应用：`ViewScope/ViewScope.xcodeproj/project.pbxproj`
- 宿主 framework：`ViewScopeServer/ViewScopeServer.xcodeproj/project.pbxproj`
- CocoaPods / runtime：`ViewScopeServer/ViewScopeServer.podspec`

常用脚本：

```bash
./scripts/build_dmg.sh
./scripts/publish_github_release.sh --notes-file release-notes/v1.0.0.md
./scripts/generate_appcast.sh --archive build/dmg/ViewScope_V_1.0.0.dmg --notes-file release-notes/v1.0.0.md
```

其中：

- `build_dmg.sh` 会构建通用二进制、重新签名、生成 DMG，并默认提交 notarization
- `publish_github_release.sh` 会创建或更新 GitHub Release，并同步刷新 `appcast.xml`
- `generate_appcast.sh` 会把发布说明内嵌到 Sparkle feed，避免额外跳网页

## 备注

- `ViewScopeServer/README.md` 提供宿主侧更聚焦的说明
- `READMEAssets/` 中的截图由测试自动生成，可通过 `ViewScopeTests.renderReadmeScreenshots` 刷新
