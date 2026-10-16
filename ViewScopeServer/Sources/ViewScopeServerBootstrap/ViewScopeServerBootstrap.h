#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 链接锚点：宿主通过 `-u _ViewScopeServerBootstrapAnchor` 强制链接本目标，保证自动启动的构造函数生效。
FOUNDATION_EXPORT void ViewScopeServerBootstrapAnchor(void);

/// Console 调用器：基于 NSMethodSignature + NSInvocation 安全地调用任意 ObjC 方法。
///
/// 参数数组中每个元素是一个字典：
/// - `@"kind"`：`@"number"` / `@"bool"` / `@"nil"` / `@"string"` / `@"color"` / `@"struct"` / `@"object"`；
/// - `@"value"`：number/bool 为 NSNumber；string 为 NSString；color 为 4 个 NSNumber（sRGB r/g/b/a，0~1）；
///   struct 为若干 NSNumber（{x, y} / {w, h} / {x, y, w, h} / {top, left, bottom, right}）；object 为对象本身。
///
/// 返回字典：
/// - 失败：`@"error"` → NSString；
/// - 成功：`@"returnType"` → 类型编码；`@"isVoid"` → @YES（void 返回）；
///   `@"object"` → 返回的对象（id / Class / CGColorRef 等），返回 nil 对象时为 `@"isNil"` → @YES；
///   `@"description"` → 非对象返回值的文字描述（BOOL 为 YES/NO，数字、结构体等）。
@interface ViewScopeConsoleInvoker : NSObject

+ (NSDictionary<NSString *, id> *)invokeSelectorNamed:(NSString *)selectorName
                                             onTarget:(id)target
                                            arguments:(NSArray<NSDictionary<NSString *, id> *> *)arguments;

@end

NS_ASSUME_NONNULL_END
