# 服务端审计（2026-10-16，静态阅读）

## A. 严重
- A1 无认证门禁：`handle(message:)` 不检查连接是否完成 `clientHello`，capture/mutation/console 均可直接执行；authToken 每 2 秒明文广播。修复：连接级 `isAuthenticated`。
- A2 旧连接的 onDisconnect 清空新连接（Inspector.swift `accept`）：先 cancel 旧连接，旧连接 `.cancelled` 异步回调执行 `activeConnection = nil` 把新连接清掉，客户端永久挂起。修复：比较身份后再清空。
- A3 请求不回响应：Connection.swift 解码失败 `try?` 丢弃；编码失败静默 return（NaN/Inf 让整个 capture 发不出去）；`default: break`、多处 `guard ... else { return }` 未回 error。
- A4 Mutation 数值转换 trap：`UInt(value)` / `Int(value)` / `UInt(Int(value))` 遇负数或 1e30 让宿主崩溃（imageScaling、borderType、各种 style/enum key）。修复：`isFinite` + `Int(exactly:)`。
- A5 Console 不安全：`responds(to:)` 后直接 `value(forKey:)`；带冒号 selector 抛 NSUnknownKeyException；`release`/`dealloc` 被 KVC 当 getter 调用造成过度释放；返回 SEL/char* 抛异常。
- A6 consoleObjectCache 无上限强引用，`stop()` 不清理。
- A7 Swift ivar 追踪泄漏与野指针：`Unmanaged.fromOpaque(rawPtr).retain().takeUnretainedValue()` 的 +1 从不释放；空类型编码的 Swift ivar 可能是 Int/struct/closure/裸指针，`malloc_size > 0` 不能证明是对象。
- A8 ObjC ivar 遍历进入 AppKit 私有类（终止集合只精确匹配 5 个类名），悬挂 assign ivar 会崩溃。修复：`class_getImageName` 判断，跳过 `/System/Library/` 下的类。
- A9 lastReferenceContext 强持有整棵树，关闭的窗口/移除的视图一直存活；对脱离窗口的视图 mutation 仍 ack。
- A10 `cell?.value(forKey: "_buttonType")` 无保护的私有 KVC。

## B. 逻辑和坐标
- B1 绝大多数节点是 `.layer`（layer-backed 视图），detail 走 layerSections，没有 control/AppKit 专属分区，constraints 为空，mutation 走 CALayer 版本。视图级编辑在真实宿主中基本不可达（测试手工构造 `.view` 引用所以没暴露）。
- B2 对宿主 backing layer 直接改 frame/bounds/hidden/opacity，下一次布局被覆盖，view 状态与 layer 脱节。
- B3 `rootLayer: rootLayer ?? childLayer` 导致纯 CALayer 子树坐标相对错误的 layer 计算后又按 rootView 高度翻转。
- B4 VC 归属不一致：layer 节点 `rootViewControllerClassName` 用了非精确 `viewScopeOwningViewController`；layer 的 ivar trace 混入祖先 VC trace；console target 给非精确 VC，解析时用精确 VC，取不到回退成 layer。
- B5 高亮浮层（NSPanel）会出现在抓取结果里（过滤条件要求类名含 ViewScope）。
- B6 节点 ID 按位置生成（`window-0-layer-3-1`），跨抓取不稳定；console reference 不校验 captureID。
- B7 本地化 key `server.item.bounds_x/_y/_width/_height` 缺失。
- B8 截图方向约定互相矛盾（`lockFocusFlipped(!isGeometryFlipped)` vs `lockFocusFlipped(isGeometryFlipped)`；`normalizedScreenshot` 注释说翻转但代码未翻转）；`makeLayerScreenshot` 是死代码。
- B9 solo 截图只隐藏 sublayer，隐式 layer-backing 走 cacheDisplay 时子视图仍被画进来（推测）；修改 isHidden 未禁用隐式动画。
- B10 无 layer 视图的 solo 图全透明却仍编码发送。
- B11 Console `case let bool as Bool` 在 NSNumber 前，0/1 数字显示成 true/false。
- B12 性能：capture/PNG/JSON 全在主线程；不可见窗口也完整遍历并生成 solo 截图；ImageEncoder 绕道 TIFF；trace 每视图标记两次；incomingBuffer 无上限。
- B13 窗口高亮未 convert；`mutateViewFrame` 立即对 superview layout，Auto Layout 视图被瞬间还原仍 ack；颜色用 deviceRGB（应 sRGB）。

## 半成品
- `contentInsets.*` 能处理但从不下发；`backgroundColor` 只有已有背景色时才出现，无法从无到有设置。
- 枚举全部以裸数字编辑。
- `groupPNGBase64` 恒为 nil；`.viewController`/`.object` 引用从不产生。
- AppKit 分区标题与条目大量硬编码英文（"Font Name"、"Hosted View"、"Masks To Bounds"、"Scroll View"…）。
- `control.value` 对 NSButton 改 title，与 `button.title` 重复。
- `CGWindowListCreateImage` 在 macOS 15 起 obsoleted，需要保留可用的回退路径。
