import Foundation

/// 基于主 RunLoop（common modes）的轻量调度工具，用于合并高频事件与输入防抖。
///
/// 相比 `DispatchQueue.main.async` / `Task.sleep`：
/// - 在滚动、拖拽等 tracking 模式下也会执行；
/// - 在嵌套 RunLoop（例如测试里手动推进 RunLoop）中同样可以执行。
enum MainRunLoopScheduler {
    /// 在下一个 RunLoop 周期执行。
    static func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                block()
            }
        }
    }

    /// 延迟执行，返回的 Timer 可用于取消（`invalidate()`）。
    @discardableResult
    static func schedule(after delay: TimeInterval, _ block: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                block()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
