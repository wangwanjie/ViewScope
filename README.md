# ViewScope

ViewScope 是一个面向原生 macOS 开发的 UI 调试工具，目标是在 AppKit 项目里提供类似 Lookin / Reveal 的实时层级查看、属性检查、截图预览、节点高亮与调试辅助体验，同时尽量保持集成成本低、数据只在本机流动。

## 特性

- 原生 AppKit 客户端，包含主窗口、状态栏入口、偏好设置、文件导入导出与 Sparkle 更新检查
- 自动发现并连接本机 Debug 宿主，使用 `DistributedNotificationCenter` 广播 + `127.0.0.1` TCP 握手通信
- 支持实时捕获刷新，连接新宿主或刷新时会显示顶部进度条加载状态
- 左侧提供宿主列表与层级树搜索，中间提供 2D 和 3D 两种预览模式，支持缩放、聚焦、显隐切换与节点高亮
- 右侧 Inspector 支持查看并直接修改常见属性，包括文本、数值、开关、四边值和颜色
- 内置调试控制台，可跟随当前选中节点同步目标并提交表达式
- 支持导入和导出 `.viewscope` 捕获文件，便于离线查看与共享
- 支持中英文界面、本地偏好持久化，以及通过 GRDB 记录最近连接宿主与捕获耗时

## 截图

<p>
  <img src="READMEAssets/main-window.png" alt="ViewScope 主窗口" width="100%" />
</p>
<p>
  <img src="READMEAssets/preferences.png" alt="ViewScope 偏好设置窗口" width="720" />
</p>

## 项目结构

- `ViewScope/`: 主应用工程，使用 SnapKit、GRDB、Sparkle 和本地 `ViewScopeServer` 包
- `ViewScopeServer/`: 宿主侧运行时，包含源码、CocoaPods podspec、Carthage framework 工程
- `Package.swift`: 仓库根目录的 SwiftPM 入口，对外暴露 `ViewScopeServer`
- `READMEAssets/`: README 截图资源，由测试自动生成
- `ViewScope/ViewScopeTests/`: 主应用测试，覆盖界面状态、预览渲染和交互回归

## 本地开发

要求：

- macOS 11.0+
- Xcode（当前仓库已在本机 Xcode 17C529 环境完成构建与测试）

日常开发建议直接打开 `ViewScope/ViewScope.xcodeproj`。若只验证宿主侧库，也可以直接使用根目录 `Package.swift` 或 `ViewScopeServer/Package.swift`。

常用命令：

```bash
xcodebuild \
  -project ViewScope/ViewScope.xcodeproj \
  -scheme ViewScope \
  -destination 'platform=macOS' \
  test

swift test
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
.package(url: "https://github.com/wangwanjie/ViewScope.git", from: "1.2.2")
```

仓库根目录直接提供 `Package.swift`，Xcode / SwiftPM 可以直接依赖整个仓库 URL，无需指向 `ViewScopeServer/` 子目录。

把 `ViewScopeServer` product 加到 Debug 宿主 target：

```swift
import ViewScopeServer
```

默认情况下，只要库被加载到 Debug 构建中，`ViewScopeServer` 会在宿主应用完成启动后自动启用。

如果你想自己控制启用时机，可以在很早期先关闭自动启用，再在合适的时机手动调用 `start()`：

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

如果你的 macOS Debug 宿主启用了 `App Sandbox`，请先把 Debug 配置里的 `ENABLE_APP_SANDBOX` 关掉。当前发现层使用 `DistributedNotificationCenter`，而系统默认的 app sandbox 不允许普通应用发送这类 discovery 广播，所以客户端会一直看不到 `Live Hosts`。

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

然后执行：

```bash
carthage update --use-xcframeworks --platform macOS
```

将生成的 `ViewScopeServer.framework` 链接到 Debug 宿主即可；默认会在启动完成后自动启用。

## 使用方式

1. 启动 ViewScope。
2. 运行已集成 `ViewScopeServer` 的 Debug 宿主应用。
3. 在工具栏或左侧 `Live Hosts` 里选择宿主，ViewScope 会通过 loopback 建立连接。
4. 在层级树中搜索或选中节点，主预览区可切换 2D / 3D，并支持缩放、聚焦、显隐和高亮。
5. 右侧 Inspector 会显示属性、约束与布局信息；支持的字段可以直接修改并回写宿主。
6. 需要时可打开控制台执行表达式，或通过菜单导入 / 导出 `.viewscope` 捕获文件。

## 状态栏设计

ViewScope 会常驻一个 `VS` 状态栏入口：

- 实时显示当前是否已连接宿主，并可选展示连接计数
- 直接打开主窗口、刷新当前捕获、开关自动刷新和自动高亮
- 展示最近发现的本机宿主列表，便于快速连接
- 提供偏好设置、检查更新和退出入口

## 偏好设置

当前偏好设置主要包含两组：

- 通用：界面语言、自动刷新、自动高亮、状态栏连接计数
- 更新：检查更新策略、自动下载更新、手动检查更新与 GitHub 主页入口

## 安全与性能

- 发现和采集数据默认只在本机传输，不依赖远端服务
- 宿主监听地址固定在 `127.0.0.1`，并使用一次性 token 完成握手
- 默认只建议在 Debug 构建里启用 `ViewScopeServer`
- 对于 sandboxed 的 macOS 宿主，建议专门准备一个关闭 `App Sandbox` 的 Debug 配置
- 捕获历史限制为最近 250 条，避免数据库持续膨胀
