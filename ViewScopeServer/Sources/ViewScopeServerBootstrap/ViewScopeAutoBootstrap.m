#import "ViewScopeServerBootstrap.h"
#import <TargetConditionals.h>
#import <objc/message.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

static void ViewScopeInspectorPerformAutomaticStart(void) {
    Class bridgeClass = NSClassFromString(@"ViewScopeAutomaticStartBridge");
    SEL selector = @selector(performAutomaticStart);

    if (bridgeClass == Nil || ![bridgeClass respondsToSelector:selector]) {
        return;
    }

    ((void (*)(id, SEL))objc_msgSend)(bridgeClass, selector);
}

void ViewScopeServerBootstrapAnchor(void) {
    // 引用 console 调用器的类符号，保证静态链接时 ViewScopeConsoleInvoker.o 不会被裁掉。
    (void)[ViewScopeConsoleInvoker class];
}

#if TARGET_OS_OSX

static void ViewScopeInstallAutomaticStartObserver(void) {
    // 先注册通知，再异步检查一次：应用已经完成启动（例如库被延迟加载）时直接启动。
    __block id observer = nil;
    observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                                object:nil
                                                                 queue:[NSOperationQueue mainQueue]
                                                            usingBlock:^(__unused NSNotification *note) {
        if (observer != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            observer = nil;
        }
        ViewScopeInspectorPerformAutomaticStart();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSApplication *application = NSApp;
        if (application != nil && application.running) {
            ViewScopeInspectorPerformAutomaticStart();
        }
    });
}

#else

static void ViewScopeInstallAutomaticStartObserver(void) {
    __block id observer = nil;
    observer = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                object:nil
                                                                 queue:[NSOperationQueue mainQueue]
                                                            usingBlock:^(__unused NSNotification *note) {
        if (observer != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            observer = nil;
        }
        ViewScopeInspectorPerformAutomaticStart();
    }];

    // 构造函数运行在 main() 之前；此时 sharedApplication 已存在，说明库是在应用启动后才被加载的，
    // didFinishLaunching 通知不会再来，需要直接启动。应用扩展中没有 sharedApplication，按类名动态获取。
    Class applicationClass = NSClassFromString(@"UIApplication");
    SEL sharedSelector = NSSelectorFromString(@"sharedApplication");
    if (applicationClass == Nil || ![applicationClass respondsToSelector:sharedSelector]) {
        return;
    }
    id application = ((id (*)(id, SEL))objc_msgSend)(applicationClass, sharedSelector);
    if (application != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewScopeInspectorPerformAutomaticStart();
        });
    }
}

#endif

__attribute__((constructor))
static void ViewScopeBootstrapEntry(void) {
    ViewScopeInstallAutomaticStartObserver();
}
