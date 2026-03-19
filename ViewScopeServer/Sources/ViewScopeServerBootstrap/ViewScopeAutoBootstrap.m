#import "ViewScopeServerBootstrap.h"
#import <AppKit/AppKit.h>
#import <objc/message.h>

static void ViewScopeInspectorPerformAutomaticStart(void) {
    Class bridgeClass = NSClassFromString(@"ViewScopeAutomaticStartBridge");
    SEL selector = @selector(performAutomaticStart);

    if (bridgeClass == Nil || ![bridgeClass respondsToSelector:selector]) {
        return;
    }

    ((void (*)(id, SEL))objc_msgSend)(bridgeClass, selector);
}

void ViewScopeServerBootstrapAnchor(void) {
}

static void ViewScopeInstallAutomaticStartObserver(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSApplication *application = NSApp;
        if (application != nil && application.running) {
            ViewScopeInspectorPerformAutomaticStart();
            return;
        }

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
    });
}

__attribute__((constructor))
static void ViewScopeBootstrapEntry(void) {
    ViewScopeInstallAutomaticStartObserver();
}
