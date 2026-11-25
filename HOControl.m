#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

@class HOSwitch;

#define HO_MENU_TAG 981372
#define HO_ICON_TAG 981373
#define HO_ALPHA_LABEL_TAG 981374
#define HO_SIZE_LABEL_TAG 981375
#define HO_PANEL_WIDTH 380.0
#define HO_PANEL_HEIGHT 660.0
#define HO_ICON_SIZE 56.0

static NSString *const HOIconImageURL = @"https://imgs.search.brave.com/Gll420MeLwA4SVJxJEp_QrJQbBsytXon6-FLTXpSt08/rs:fit:860:0:0:0/g:ce/aHR0cHM6Ly9pbWFn/ZXMucGV4ZWxzLmNv/bS9waG90b3MvMzg4/MDA0OS9wZXhlbHMt/cGhvdG8tMzg4MDA0/OS5qcGVnP2NzPXRp/bnlzcmdiJmRwcj0x/Jnc9NTAw";

@interface HOOverlayWindow : UIWindow
@end

@implementation HOOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface HOMenu : NSObject
+ (void)show;
+ (void)hide;
+ (void)installGesture;
+ (void)handlePan:(UIPanGestureRecognizer *)gesture;
+ (void)handlePinch:(UIPinchGestureRecognizer *)gesture;
+ (void)handleIconPan:(UIPanGestureRecognizer *)gesture;
+ (void)minimize;
+ (void)restore;
+ (void)resetZoom;
+ (UIColor *)textColor;
+ (UIView *)menuPanel;
+ (void)showFunctions;
+ (void)showSettings;
+ (void)toggleStreamMode;
+ (void)alphaChanged:(UISlider *)slider;
+ (void)sizeChanged:(UISlider *)slider;
+ (void)languageChanged:(UISegmentedControl *)control;
+ (void)selectColor:(UIButton *)button;
+ (void)useDarkTheme;
+ (void)useLightTheme;
+ (void)closePanel;
+ (void)hidePanelOnly;
+ (UIWindow *)appWindow;
+ (CGPoint)baseMenuCenter;
+ (CGPoint)menuCenter;
+ (CGPoint)floatingIconCenter;
+ (UIButton *)floatingIcon;
+ (void)loadIconImageForButton:(UIButton *)button;
+ (UIViewController *)topViewController;
+ (void)change:(HOSwitch *)sender;
+ (void)allOn;
+ (void)allOff;
@end

typedef NS_ENUM(NSInteger, HOToggle) {
    HOToggleScreenshot = 0,
    HOToggleRecord,
    HOToggleLogout,
    HOToggleSessionJS,
    HOToggleLockWarning,
    HOToggleCount
};

static BOOL hoStates[HOToggleCount] = {NO, NO, NO, NO, NO};
static IMP HOOrigAddObserverBlock;
static IMP HOOrigAddObserverTarget;
static IMP HOOrigAddScriptHandler;
static IMP HOOrigRemoveScriptHandler;
static IMP HOOrigEvaluateJS;
static IMP HOOrigPresentVC;
static NSMutableDictionary<NSString *, NSValue *> *hoPluginOriginals;
static NSMutableDictionary<NSString *, NSValue *> *hoLifecycleOriginals;
static NSMutableArray<NSMutableDictionary *> *hoBlockObservers;
static NSMutableArray<NSMutableDictionary *> *hoTargetObservers;
static NSHashTable<WKUserContentController *> *hoScriptControllers;
static NSMutableSet<NSValue *> *hoHookedMethods;
static UITapGestureRecognizer *hoGesture;
static id hoGestureTarget;
static UIWindow *hoMenuWindow;
static CGPoint hoMenuOffset = {0.0, 0.0};
static CGPoint hoPanStartCenter = {0.0, 0.0};
static CGFloat hoMenuScale = 1.0;
static CGFloat hoPinchStartScale = 1.0;
static CGPoint hoIconCenter = {0.0, 0.0};
static CGPoint hoIconPanStart = {0.0, 0.0};
static BOOL hoIconVisible = NO;
static BOOL hoStreamMode = NO;
static CGFloat hoMenuAlpha = 1.0;
static NSInteger hoLanguage = 0;
static NSInteger hoTheme = 0;
static NSInteger hoTab = 0;
static NSInteger hoAccentColorIndex = 0;
static NSTimeInterval hoLastTapTime = 0;

static BOOL HOUnblocked(HOToggle toggle) {
    return hoStates[toggle];
}

static NSString *HOLocalized(NSString *vietnamese, NSString *english, NSString *chinese) {
    if (hoLanguage == 1) {
        return english;
    }
    if (hoLanguage == 2) {
        return chinese;
    }
    return vietnamese;
}

static UIColor *HOAccentColor(void) {
    NSArray<UIColor *> *colors = @[
        [UIColor colorWithRed:0.18 green:0.78 blue:0.95 alpha:1],
        [UIColor colorWithRed:1.0 green:0.32 blue:0.36 alpha:1],
        [UIColor colorWithRed:0.66 green:0.42 blue:0.98 alpha:1],
        [UIColor colorWithRed:0.30 green:0.86 blue:0.52 alpha:1],
        [UIColor colorWithRed:1.0 green:0.70 blue:0.22 alpha:1]
    ];
    return colors[(NSUInteger)hoAccentColorIndex % colors.count];
}

static NSString *HOFeatureDetail(HOToggle toggle, BOOL on) {
    if (!on) {
        return HOLocalized(@"Tắt: giữ bảo vệ của app", @"Off: keep app protection", @"关：保留应用防护");
    }
    switch (toggle) {
        case HOToggleScreenshot:
            return HOLocalized(@"Bật: chụp thường, không đen", @"On: screenshots work normally", @"开：正常截图，不黑屏");
        case HOToggleRecord:
            return HOLocalized(@"Bật: quay màn hình bình thường", @"On: screen recording works", @"开：可正常录屏");
        case HOToggleLogout:
            return HOLocalized(@"Bật: logout / log chạy lại", @"On: logout / logging works", @"开：允许退出与记录");
        case HOToggleSessionJS:
            return HOLocalized(@"Bật: JS session/device chạy lại", @"On: session/device JS works", @"开：允许会话与设备 JS");
        case HOToggleLockWarning:
            return HOLocalized(@"Bật: không gắn cờ rời bài", @"On: no leave-page flag", @"开：不标记离开页面");
        default:
            return HOLocalized(@"Bật: MOD đang mở", @"On: MOD is allowing this", @"开：MOD 正在放行");
    }
}

static NSSet<NSString *> *HOScreenshotNotificationNames(void) {
    return [NSSet setWithObjects:UIApplicationUserDidTakeScreenshotNotification, UIScreenCapturedDidChangeNotification, nil];
}

static NSSet<NSString *> *HORecordNotificationNames(void) {
    return [NSSet setWithObjects:UIScreenCapturedDidChangeNotification, nil];
}

static NSSet<NSString *> *HOLifecycleNotificationNames(void) {
    return [NSSet setWithObjects:UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification, nil];
}

static NSSet<NSString *> *HOLogoutHandlerNames(void) {
    return [NSSet setWithObjects:@"app_dang_xuat", @"app_co_phien", @"app_khong_vao_duoc", nil];
}

static NSArray<NSString *> *HOBlockedJSMarkers(void) {
    return @[@"ph_thiet_bi_app_tu_app", @"app_da_co_phien", @"app_khong_vao_duoc", @"app_dang_xuat", @"__luiTrongTrang", @"fltConsoleMessage"];
}

static void HORemoveViewsInView(UIView *view) {
    for (UIView *subview in view.subviews.copy) {
        NSString *name = NSStringFromClass(subview.class);
        if ([name containsString:@"ScreenshotProtection"] || [name containsString:@"ScreenshotPrevent"] || [name containsString:@"ScreenProtect"]) {
            subview.hidden = YES;
            [subview removeFromSuperview];
        } else {
            HORemoveViewsInView(subview);
        }
    }
}

static void HORemoveProtectionViews(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        HORemoveViewsInView(window);
    }
}

static id HOUnboxed(id value) {
    return [value isKindOfClass:NSNull.class] ? nil : value;
}

static void HORemoveBlockObserversForNames(NSSet<NSString *> *names) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSMutableDictionary *record in hoBlockObservers.copy) {
        NSString *name = HOUnboxed(record[@"name"]);
        if (![names containsObject:name]) {
            continue;
        }
        id token = HOUnboxed(record[@"token"]);
        if (token) {
            [center removeObserver:token];
        }
        [hoBlockObservers removeObjectIdenticalTo:record];
    }
}

static void HORemoveTargetObserversForNames(NSSet<NSString *> *names) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSMutableDictionary *record in hoTargetObservers.copy) {
        NSString *name = HOUnboxed(record[@"name"]);
        if (![names containsObject:name]) {
            continue;
        }
        id target = [record[@"target"] nonretainedObjectValue];
        id object = HOUnboxed(record[@"object"]);
        if (target) {
            [center removeObserver:target name:name object:object];
        }
        [hoTargetObservers removeObjectIdenticalTo:record];
    }
}

static void HORemoveLogoutScriptHandlers(void) {
    if (!HOOrigRemoveScriptHandler) {
        return;
    }
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))HOOrigRemoveScriptHandler;
    SEL selector = @selector(removeScriptMessageHandlerForName:);
    for (WKUserContentController *controller in hoScriptControllers) {
        for (NSString *name in HOLogoutHandlerNames()) {
            original(controller, selector, name);
        }
    }
}

static void HOApplyToggle(HOToggle toggle, BOOL unblocked) {
    hoStates[toggle] = unblocked;
    if (unblocked && toggle == HOToggleScreenshot) {
        HORemoveProtectionViews();
        HORemoveBlockObserversForNames(HOScreenshotNotificationNames());
        HORemoveTargetObserversForNames(HOScreenshotNotificationNames());
    }
    if (unblocked && toggle == HOToggleRecord) {
        HORemoveBlockObserversForNames(HORecordNotificationNames());
        HORemoveTargetObserversForNames(HORecordNotificationNames());
    }
    if (unblocked && toggle == HOToggleLogout) {
        HORemoveLogoutScriptHandlers();
    }
}

static void HOReplaceMethod(Class cls, SEL selector, const char *aliasName, id block, IMP *originalOut) {
    if (!cls || !selector || !block) {
        return;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }
    NSValue *key = [NSValue valueWithPointer:method];
    if ([hoHookedMethods containsObject:key]) {
        return;
    }
    [hoHookedMethods addObject:key];
    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    *originalOut = original;
    SEL alias = sel_registerName(aliasName);
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, alias, replacement, types)) {
        Method aliasMethod = class_getInstanceMethod(cls, alias);
        if (aliasMethod) {
            method_setImplementation(aliasMethod, replacement);
        }
    }
    Method aliasMethod = class_getInstanceMethod(cls, alias);
    if (aliasMethod) {
        method_exchangeImplementations(method, aliasMethod);
    }
}

static void HOHookNotificationCenter(void) {
    Class centerClass = NSNotificationCenter.class;

    HOReplaceMethod(centerClass, @selector(addObserverForName:object:queue:usingBlock:), "ho_addObserverForName:object:queue:usingBlock:", ^id(id self, NSString *name, id object, NSOperationQueue *queue, void (^notificationBlock)(NSNotification *)) {
        BOOL allowed = YES;
        if ([HOScreenshotNotificationNames() containsObject:name]) {
            allowed = !HOUnblocked(HOToggleScreenshot);
        } else if ([HORecordNotificationNames() containsObject:name]) {
            allowed = !HOUnblocked(HOToggleRecord);
        } else if ([HOLifecycleNotificationNames() containsObject:name]) {
            allowed = !HOUnblocked(HOToggleLockWarning);
        }
        if (!allowed) {
            return [NSObject new];
        }
        id (*original)(id, SEL, NSString *, id, NSOperationQueue *, void (^)(NSNotification *)) = (void *)HOOrigAddObserverBlock;
        SEL selector = @selector(addObserverForName:object:queue:usingBlock:);
        id token = original ? original(self, selector, name, object, queue, notificationBlock) : nil;
        id storedToken = token ?: [NSObject new];
        NSMutableDictionary *record = [NSMutableDictionary dictionary];
        record[@"token"] = storedToken;
        record[@"name"] = name ?: NSNull.null;
        [hoBlockObservers addObject:record];
        return storedToken;
    }, &HOOrigAddObserverBlock);

    HOReplaceMethod(centerClass, @selector(addObserver:selector:name:object:), "ho_addObserver:selector:name:object:", ^void(id self, id observer, SEL selector, NSString *name, id object) {
        BOOL allowed = YES;
        if ([HOScreenshotNotificationNames() containsObject:name]) {
            allowed = !HOUnblocked(HOToggleScreenshot);
        } else if ([HORecordNotificationNames() containsObject:name]) {
            allowed = !HOUnblocked(HOToggleRecord);
        } else if ([HOLifecycleNotificationNames() containsObject:name]) {
            allowed = !HOUnblocked(HOToggleLockWarning);
        }
        if (!allowed) {
            return;
        }
        void (*original)(id, SEL, id, SEL, NSString *, id) = (void *)HOOrigAddObserverTarget;
        if (original) {
            original(self, @selector(addObserver:selector:name:object:), observer, selector, name, object);
        }
        NSMutableDictionary *record = [NSMutableDictionary dictionary];
        record[@"target"] = [NSValue valueWithNonretainedObject:observer];
        record[@"selector"] = NSStringFromSelector(selector) ?: NSNull.null;
        record[@"name"] = name ?: NSNull.null;
        record[@"object"] = object ?: NSNull.null;
        [hoTargetObservers addObject:record];
    }, &HOOrigAddObserverTarget);
}

static void HOHookWebView(void) {
    HOReplaceMethod(WKUserContentController.class, @selector(addScriptMessageHandler:name:), "ho_addScriptMessageHandler:name:", ^void(WKUserContentController *self, id<WKScriptMessageHandler> handler, NSString *name) {
        [hoScriptControllers addObject:self];
        if (HOUnblocked(HOToggleLogout) && [HOLogoutHandlerNames() containsObject:name]) {
            return;
        }
        void (*original)(id, SEL, id, NSString *) = (void *)HOOrigAddScriptHandler;
        if (original) {
            original(self, @selector(addScriptMessageHandler:name:), handler, name);
        }
    }, &HOOrigAddScriptHandler);

    HOReplaceMethod(WKUserContentController.class, @selector(removeScriptMessageHandlerForName:), "ho_removeScriptMessageHandlerForName:", ^void(WKUserContentController *self, NSString *name) {
        [hoScriptControllers addObject:self];
        void (*original)(id, SEL, NSString *) = (void *)HOOrigRemoveScriptHandler;
        if (original) {
            original(self, @selector(removeScriptMessageHandlerForName:), name);
        }
    }, &HOOrigRemoveScriptHandler);

    HOReplaceMethod(WKWebView.class, @selector(evaluateJavaScript:completionHandler:), "ho_evaluateJavaScript:completionHandler:", ^void(WKWebView *self, NSString *script, void (^completion)(id, NSError *)) {
        if (HOUnblocked(HOToggleSessionJS)) {
            for (NSString *marker in HOBlockedJSMarkers()) {
                if ([script containsString:marker]) {
                    if (completion) {
                        completion(nil, nil);
                    }
                    return;
                }
            }
        }
        void (*original)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)HOOrigEvaluateJS;
        if (original) {
            original(self, @selector(evaluateJavaScript:completionHandler:), script, completion);
        }
    }, &HOOrigEvaluateJS);
}

static BOOL HOIsScreenshotMethod(NSString *method) {
    if ([method isEqualToString:@"preventScreenshotOn"] || [method isEqualToString:@"enablePreventScreenshot"] || [method isEqualToString:@"applyPreventScreenshotProtection"] || [method isEqualToString:@"configurePreventionScreenshot"]) {
        return YES;
    }
    if ([method hasPrefix:@"enableScreenshotBlocking"]) {
        return YES;
    }
    if ([method hasPrefix:@"protectDataLeakage"] && ![method hasSuffix:@"Off"]) {
        return YES;
    }
    return NO;
}

static BOOL HOIsRecordMethod(NSString *method) {
    return [method isEqualToString:@"preventScreenRecordOn"] || [method isEqualToString:@"enablePreventScreenRecording"];
}

static void HOAnswer(id result, id value) {
    if (!result) {
        return;
    }
    void (^callback)(id) = (void (^)(id))result;
    callback(value);
}

static void HOHookPlugins(void) {
    NSArray<NSString *> *classNames = @[@"_TtC16screen_protector26SwiftScreenProtectorPlugin", @"SwiftScreenProtectorPlugin", @"ScreenProtectorPlugin"];
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            continue;
        }
        IMP capturedOriginal = NULL;
        HOReplaceMethod(cls, @selector(handleMethodCall:result:), "ho_handleMethodCall:result:", ^void(id self, id call, id result) {
            NSString *method = nil;
            @try {
                method = [call valueForKey:@"method"];
            } @catch (__unused NSException *exception) {
                method = nil;
            }
            if (HOUnblocked(HOToggleScreenshot) && HOIsScreenshotMethod(method)) {
                HOAnswer(result, @YES);
                return;
            }
            if ([method isEqualToString:@"isPreventScreenshotEnabled"] && HOUnblocked(HOToggleScreenshot)) {
                HOAnswer(result, @NO);
                return;
            }
            if (HOUnblocked(HOToggleRecord) && HOIsRecordMethod(method)) {
                HOAnswer(result, @YES);
                return;
            }
            if ([method isEqualToString:@"isPreventScreenRecordingEnabled"] && HOUnblocked(HOToggleRecord)) {
                HOAnswer(result, @NO);
                return;
            }
            IMP stored = (IMP)[hoPluginOriginals[className] pointerValue];
            void (*original)(id, SEL, id, id) = (void *)stored;
            if (original) {
                original(self, @selector(handleMethodCall:result:), call, result);
            }
        }, &capturedOriginal);
        if (capturedOriginal) {
            hoPluginOriginals[className] = [NSValue valueWithPointer:capturedOriginal];
        }
    }
}

static void HOHookLifecycleDelegates(void) {
    NSArray<NSDictionary *> *specs = @[
        @{@"class": @"_TtC6Runner11AppDelegate", @"selector": @"applicationWillResignActive:", @"alias": @"ho_applicationWillResignActive:"},
        @{@"class": @"_TtC6Runner11AppDelegate", @"selector": @"applicationDidEnterBackground:", @"alias": @"ho_applicationDidEnterBackground:"},
        @{@"class": @"_TtC6Runner13SceneDelegate", @"selector": @"sceneWillResignActive:", @"alias": @"ho_sceneWillResignActive:"},
        @{@"class": @"_TtC6Runner13SceneDelegate", @"selector": @"sceneDidEnterBackground:", @"alias": @"ho_sceneDidEnterBackground:"}
    ];
    for (NSDictionary *spec in specs) {
        Class cls = NSClassFromString(spec[@"class"]);
        if (!cls) {
            continue;
        }
        NSString *selectorName = spec[@"selector"];
        NSString *key = [NSString stringWithFormat:@"%@|%@", spec[@"class"], selectorName];
        SEL selector = NSSelectorFromString(selectorName);
        IMP capturedOriginal = NULL;
        HOReplaceMethod(cls, selector, [spec[@"alias"] UTF8String], ^void(id self, id argument) {
            if (HOUnblocked(HOToggleLockWarning)) {
                return;
            }
            IMP stored = (IMP)[hoLifecycleOriginals[key] pointerValue];
            void (*original)(id, SEL, id) = (void *)stored;
            if (original) {
                original(self, NSSelectorFromString(selectorName), argument);
            }
        }, &capturedOriginal);
        if (capturedOriginal) {
            hoLifecycleOriginals[key] = [NSValue valueWithPointer:capturedOriginal];
        }
    }
}

static BOOL HOLooksLikeLockWarning(UIViewController *viewController) {
    if (![viewController isKindOfClass:UIAlertController.class]) {
        return NO;
    }
    UIAlertController *alert = (UIAlertController *)viewController;
    NSString *text = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""].lowercaseString;
    NSArray<NSString *> *markers = @[@"lockwarning", @"warning", @"cảnh báo", @"canh bao", @"khoá", @"khóa", @"vi phạm", @"vi pham", @"rời bài", @"roi bai"];
    for (NSString *marker in markers) {
        if ([text containsString:marker]) {
            return YES;
        }
    }
    return NO;
}

static void HOHookAlerts(void) {
    HOReplaceMethod(UIViewController.class, @selector(presentViewController:animated:completion:), "ho_presentViewController:animated:completion:", ^void(UIViewController *self, UIViewController *viewController, BOOL animated, void (^completion)(void)) {
        if (HOUnblocked(HOToggleLockWarning) && HOLooksLikeLockWarning(viewController)) {
            if (completion) {
                completion();
            }
            return;
        }
        void (*original)(id, SEL, UIViewController *, BOOL, void (^)(void)) = (void *)HOOrigPresentVC;
        if (original) {
            original(self, @selector(presentViewController:animated:completion:), viewController, animated, completion);
        }
    }, &HOOrigPresentVC);
}

@interface HOGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation HOGestureTarget

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || gesture.view != [HOMenu appWindow]) {
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (hoLastTapTime > 0 && now - hoLastTapTime <= 1.0) {
        hoLastTapTime = 0;
        [HOMenu show];
        return;
    }
    hoLastTapTime = now;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return YES;
}

@end

@interface HOSwitch : UISwitch
@property (nonatomic) NSInteger hoIndex;
@end

@implementation HOSwitch
@end

@implementation HOMenu

+ (UIWindow *)keyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

+ (UIWindow *)appWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window == hoMenuWindow || window.tag == HO_MENU_TAG || !window.rootViewController) {
                continue;
            }
            return window;
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window != hoMenuWindow && window.tag != HO_MENU_TAG && window.rootViewController) {
            return window;
        }
    }
    return nil;
}

+ (void)installGesture {
    UIWindow *window = [self appWindow];
    if (!window || !hoGesture) {
        return;
    }
    for (UIWindow *existing in UIApplication.sharedApplication.windows.copy) {
        if (existing != window && [existing.gestureRecognizers containsObject:hoGesture]) {
            [existing removeGestureRecognizer:hoGesture];
        }
    }
    if (![window.gestureRecognizers containsObject:hoGesture]) {
        [window addGestureRecognizer:hoGesture];
    }
}

+ (UIViewController *)topViewController {
    UIViewController *controller = [self appWindow].rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController ?: controller;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController ?: controller;
    }
    return controller;
}

+ (CGPoint)baseMenuCenter {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    return CGPointMake(screen.width / 2, screen.height / 2);
}

+ (CGPoint)menuCenter {
    CGPoint base = [self baseMenuCenter];
    return CGPointMake(base.x + hoMenuOffset.x, base.y + hoMenuOffset.y);
}

+ (CGPoint)floatingIconCenter {
    if (hoIconCenter.x == 0.0 && hoIconCenter.y == 0.0) {
        CGSize screen = UIScreen.mainScreen.bounds.size;
        hoIconCenter = CGPointMake(screen.width - HO_ICON_SIZE, 140.0);
    }
    return hoIconCenter;
}

+ (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *panel = gesture.view;
    if (!panel || !panel.superview) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        hoPanStartCenter = panel.center;
    }
    CGPoint translation = [gesture translationInView:panel.superview];
    CGPoint next = CGPointMake(hoPanStartCenter.x + translation.x, hoPanStartCenter.y + translation.y);
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat halfWidth = panel.frame.size.width / 2;
    CGFloat halfHeight = panel.frame.size.height / 2;
    next.x = MIN(MAX(next.x, halfWidth + 6), screen.width - halfWidth - 6);
    next.y = MIN(MAX(next.y, halfHeight + 6), screen.height - halfHeight - 6);
    panel.center = next;
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        CGPoint base = [self baseMenuCenter];
        hoMenuOffset = CGPointMake(next.x - base.x, next.y - base.y);
    }
}

+ (void)handlePinch:(UIPinchGestureRecognizer *)gesture {
    UIView *panel = gesture.view;
    if (!panel) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        hoPinchStartScale = hoMenuScale;
    }
    CGFloat scale = hoPinchStartScale * gesture.scale;
    hoMenuScale = MIN(MAX(scale, 0.10), 1.0);
    panel.transform = CGAffineTransformMakeScale(hoMenuScale, hoMenuScale);
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        hoPinchStartScale = hoMenuScale;
    }
}

+ (void)handleIconPan:(UIPanGestureRecognizer *)gesture {
    UIView *icon = gesture.view;
    if (!icon) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        hoIconPanStart = icon.center;
    }
    CGPoint translation = [gesture translationInView:icon.superview];
    CGPoint next = CGPointMake(hoIconPanStart.x + translation.x, hoIconPanStart.y + translation.y);
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat half = HO_ICON_SIZE / 2 + 6;
    next.x = MIN(MAX(next.x, half), screen.width - half);
    next.y = MIN(MAX(next.y, half), screen.height - half);
    icon.center = next;
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        hoIconCenter = next;
    }
}

+ (void)loadIconImageForButton:(UIButton *)button {
    NSURL *url = [NSURL URLWithString:HOIconImageURL];
    if (!url) {
        return;
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        UIImage *image = [UIImage imageWithData:data];
        if (!image) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [button setImage:image forState:UIControlStateNormal];
            [button setTitle:nil forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFill;
            button.imageView.clipsToBounds = YES;
        });
    }];
    [task resume];
}

+ (UIButton *)floatingIcon {
    for (UIView *view in hoMenuWindow.subviews.copy) {
        if (view.tag == HO_ICON_TAG && [view isKindOfClass:UIButton.class]) {
            return (UIButton *)view;
        }
    }
    UIButton *icon = [UIButton buttonWithType:UIButtonTypeCustom];
    icon.tag = HO_ICON_TAG;
    icon.frame = CGRectMake(0, 0, HO_ICON_SIZE, HO_ICON_SIZE);
    icon.center = [self floatingIconCenter];
    icon.layer.cornerRadius = HO_ICON_SIZE / 2;
    icon.layer.borderWidth = 1.0;
    icon.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
    icon.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
    icon.clipsToBounds = YES;
    icon.imageView.contentMode = UIViewContentModeScaleAspectFill;
    icon.imageView.clipsToBounds = YES;
    icon.accessibilityLabel = @"MOD MENU BY ANONYMOUS";
    [icon setTitle:@"M" forState:UIControlStateNormal];
    [icon setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [icon addTarget:self action:@selector(restore) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleIconPan:)];
    pan.cancelsTouchesInView = NO;
    [icon addGestureRecognizer:pan];
    [self loadIconImageForButton:icon];
    return icon;
}

+ (void)show {
    if (hoIconVisible) {
        [self restore];
        return;
    }
    if (!hoMenuWindow) {
        hoMenuWindow = [[HOOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        hoMenuWindow.windowLevel = UIWindowLevelAlert + 100;
        hoMenuWindow.backgroundColor = UIColor.clearColor;
        hoMenuWindow.tag = HO_MENU_TAG;
        hoMenuWindow.hidden = YES;
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows.copy) {
        if (window != hoMenuWindow && window.tag == HO_MENU_TAG) {
            window.hidden = YES;
        }
    }
    for (UIView *view in hoMenuWindow.subviews.copy) {
        [view removeFromSuperview];
    }
    UIView *panel = [self buildPanel];
    panel.center = [self menuCenter];
    panel.alpha = 0.0;
    panel.transform = CGAffineTransformMakeScale(hoMenuScale * 0.88, hoMenuScale * 0.88);
    [hoMenuWindow addSubview:panel];
    hoMenuWindow.hidden = NO;
    hoMenuWindow.alpha = hoMenuAlpha;
    hoIconVisible = NO;
    [UIView animateWithDuration:0.36 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.15 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        panel.alpha = 1.0;
        panel.transform = CGAffineTransformMakeScale(hoMenuScale, hoMenuScale);
    } completion:nil];
}

+ (void)hide {
    hoIconVisible = NO;
    if (!hoMenuWindow) {
        return;
    }
    hoMenuWindow.hidden = YES;
    for (UIView *view in hoMenuWindow.subviews.copy) {
        [view removeFromSuperview];
    }
}

+ (UIColor *)textColor {
    return hoTheme == 0 ? UIColor.whiteColor : [UIColor colorWithWhite:0.08 alpha:1.0];
}

+ (UILabel *)labelWithText:(NSString *)text frame:(CGRect)frame fontSize:(CGFloat)size bold:(BOOL)bold {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    label.textColor = [self textColor];
    label.backgroundColor = UIColor.clearColor;
    label.numberOfLines = 2;
    return label;
}

+ (UIButton *)buttonWithTitle:(NSString *)title frame:(CGRect)frame action:(SEL)action target:(id)target {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[self textColor] forState:UIControlStateNormal];
    button.backgroundColor = hoTheme == 0 ? [UIColor colorWithWhite:1.0 alpha:0.14] : [UIColor colorWithWhite:0.0 alpha:0.09];
    button.layer.cornerRadius = 10;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

+ (UIView *)buildPanel {
    UIColor *accent = HOAccentColor();
    UIColor *rowColor = hoTheme == 0 ? [UIColor colorWithWhite:1.0 alpha:0.055] : [UIColor colorWithWhite:0.0 alpha:0.05];
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:hoTheme == 0 ? UIBlurEffectStyleDark : UIBlurEffectStyleLight];
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:effect];
    panel.frame = CGRectMake(0, 0, HO_PANEL_WIDTH, HO_PANEL_HEIGHT);
    panel.layer.cornerRadius = 22;
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor = hoTheme == 0 ? [UIColor colorWithWhite:1.0 alpha:0.16].CGColor : [UIColor colorWithWhite:0.0 alpha:0.12].CGColor;
    panel.clipsToBounds = YES;
    panel.contentView.backgroundColor = hoTheme == 0 ? [UIColor colorWithWhite:0 alpha:0.28] : [UIColor colorWithWhite:1.0 alpha:0.35];

    UIView *accentBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, HO_PANEL_WIDTH, 3)];
    accentBar.backgroundColor = accent;
    [panel.contentView addSubview:accentBar];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    [panel addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    pinch.cancelsTouchesInView = NO;
    [panel addGestureRecognizer:pinch];

    UIButton *skull = [self buttonWithTitle:@"☠" frame:CGRectMake(8, 86, 40, 40) action:@selector(showFunctions) target:self];
    skull.titleLabel.font = [UIFont systemFontOfSize:22];
    skull.backgroundColor = hoTab == 0 ? [accent colorWithAlphaComponent:0.30] : [UIColor colorWithWhite:0.5 alpha:0.12];
    [panel.contentView addSubview:skull];
    UIButton *gear = [self buttonWithTitle:@"⚙" frame:CGRectMake(8, 136, 40, 40) action:@selector(showSettings) target:self];
    gear.titleLabel.font = [UIFont systemFontOfSize:22];
    gear.backgroundColor = hoTab == 1 ? [accent colorWithAlphaComponent:0.30] : [UIColor colorWithWhite:0.5 alpha:0.12];
    [panel.contentView addSubview:gear];
    [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Chức năng", @"Functions", @"功能") frame:CGRectMake(4, 128, 48, 12) fontSize:9 bold:NO]];
    [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Cài đặt", @"Settings", @"设置") frame:CGRectMake(4, 178, 48, 12) fontSize:9 bold:NO]];

    CGFloat x = 66.0;
    CGFloat w = 270.0;
    [panel.contentView addSubview:[self labelWithText:@"MOD MENU BY ANONYMOUS" frame:CGRectMake(x, 14, 210, 26) fontSize:16 bold:YES]];
    [panel.contentView addSubview:[self labelWithText:HOLocalized(@"BẬT = chụp thường, không đen", @"ON = normal capture, no black", @"开：正常截图，不黑屏") frame:CGRectMake(x, 42, 220, 16) fontSize:11 bold:NO]];

    UIButton *closeButton = [self buttonWithTitle:@"X" frame:CGRectMake(282, 14, 28, 28) action:@selector(closePanel) target:self];
    [panel.contentView addSubview:closeButton];
    UIButton *exitButton = [self buttonWithTitle:HOLocalized(@"Thoát", @"Exit", @"退出") frame:CGRectMake(316, 14, 52, 28) action:@selector(close) target:self];
    [panel.contentView addSubview:exitButton];

    UIButton *moon = [self buttonWithTitle:@"☾" frame:CGRectMake(344, 100, 28, 28) action:@selector(useDarkTheme) target:self];
    moon.titleLabel.font = [UIFont systemFontOfSize:20];
    moon.backgroundColor = hoTheme == 0 ? [accent colorWithAlphaComponent:0.28] : [UIColor colorWithWhite:0.5 alpha:0.12];
    [panel.contentView addSubview:moon];
    UIButton *sun = [self buttonWithTitle:@"☀" frame:CGRectMake(344, 138, 28, 28) action:@selector(useLightTheme) target:self];
    sun.titleLabel.font = [UIFont systemFontOfSize:18];
    sun.backgroundColor = hoTheme == 1 ? [accent colorWithAlphaComponent:0.28] : [UIColor colorWithWhite:0.5 alpha:0.12];
    [panel.contentView addSubview:sun];

    BOOL anyOn = NO;
    for (NSInteger index = 0; index < HOToggleCount; index++) {
        if (HOUnblocked((HOToggle)index)) {
            anyOn = YES;
            break;
        }
    }
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(x, 66, w, 28)];
    pill.layer.cornerRadius = 14;
    pill.backgroundColor = anyOn ? [accent colorWithAlphaComponent:0.18] : [UIColor colorWithWhite:0.5 alpha:0.13];
    [panel.contentView addSubview:pill];
    UILabel *pillLabel = [self labelWithText:anyOn ? HOLocalized(@"TRẠNG THÁI: ĐANG MỞ CHỨC NĂNG", @"STATUS: FEATURES ON", @"状态：功能开启") : HOLocalized(@"TRẠNG THÁI: GIỮ BẢO VỆ", @"STATUS: PROTECTED", @"状态：保持防护") frame:CGRectMake(12, 5, 250, 18) fontSize:12 bold:YES];
    pillLabel.textColor = anyOn ? accent : [self textColor];
    [pill addSubview:pillLabel];

    if (hoTab == 0) {
        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"CHỨC NĂNG", @"FEATURES", @"功能") frame:CGRectMake(x, 106, 200, 16) fontSize:11 bold:YES]];
        NSArray<NSString *> *titles = @[
            HOLocalized(@"Chụp màn hình", @"Screenshot", @"截图"),
            HOLocalized(@"Quay màn hình", @"Screen record", @"录屏"),
            HOLocalized(@"Logout / log", @"Logout / log", @"退出 / 日志"),
            HOLocalized(@"Session / device JS", @"Session / device JS", @"会话 / 设备 JS"),
            HOLocalized(@"Rời bài", @"Leave page", @"离开页面")
        ];
        for (NSInteger index = 0; index < titles.count; index++) {
            CGFloat y = 128 + index * 48;
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 43)];
            row.layer.cornerRadius = 12;
            row.backgroundColor = rowColor;
            [panel.contentView addSubview:row];

            BOOL rowOn = HOUnblocked((HOToggle)index);
            UILabel *title = [self labelWithText:titles[index] frame:CGRectMake(14, 4, 190, 18) fontSize:13 bold:YES];
            [row addSubview:title];
            UILabel *detail = [self labelWithText:HOFeatureDetail((HOToggle)index, rowOn) frame:CGRectMake(14, 23, 190, 14) fontSize:10 bold:NO];
            detail.textColor = [self textColor];
            [row addSubview:detail];

            HOSwitch *toggle = [[HOSwitch alloc] initWithFrame:CGRectMake(212, 6, 51, 31)];
            toggle.hoIndex = index;
            toggle.on = rowOn;
            toggle.onTintColor = accent;
            toggle.tintColor = [UIColor colorWithWhite:0.5 alpha:0.25];
            toggle.thumbTintColor = UIColor.whiteColor;
            [toggle addTarget:self action:@selector(change:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:toggle];
        }
        [panel.contentView addSubview:[self buttonWithTitle:HOLocalized(@"Bật tất cả", @"All on", @"全开") frame:CGRectMake(x, 378, 130, 38) action:@selector(allOn) target:self]];
        [panel.contentView addSubview:[self buttonWithTitle:HOLocalized(@"Tắt tất cả", @"All off", @"全关") frame:CGRectMake(x + 140, 378, 130, 38) action:@selector(allOff) target:self]];
        [panel.contentView addSubview:[self buttonWithTitle:HOLocalized(@"Thu thành icon", @"Minimize", @"缩小为图标") frame:CGRectMake(x, 424, 130, 38) action:@selector(minimize) target:self]];
        [panel.contentView addSubview:[self buttonWithTitle:HOLocalized(@"Reset zoom", @"Reset zoom", @"重置缩放") frame:CGRectMake(x + 140, 424, 130, 38) action:@selector(resetZoom) target:self]];
        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Kéo = di chuyển · Chụm = thu phóng", @"Drag = move · Pinch = zoom", @"拖动=移动 · 捏合=缩放") frame:CGRectMake(x, 472, w, 16) fontSize:10 bold:NO]];
        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Chỉ áp dụng trong phiên hiện tại", @"Session only", @"仅本次会话") frame:CGRectMake(x, 494, w, 16) fontSize:10 bold:NO]];
    } else {
        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"CÀI ĐẶT", @"SETTINGS", @"设置") frame:CGRectMake(x, 106, 200, 16) fontSize:11 bold:YES]];

        UIView *streamRow = [[UIView alloc] initWithFrame:CGRectMake(x, 128, w, 44)];
        streamRow.layer.cornerRadius = 12;
        streamRow.backgroundColor = rowColor;
        [panel.contentView addSubview:streamRow];
        [streamRow addSubview:[self labelWithText:HOLocalized(@"Stream mode", @"Stream mode", @"直播模式") frame:CGRectMake(12, 4, 170, 18) fontSize:13 bold:YES]];
        [streamRow addSubview:[self labelWithText:HOLocalized(@"Chụp màn hình thì ẩn menu", @"Hide menu on screenshot", @"截图时隐藏菜单") frame:CGRectMake(12, 23, 184, 14) fontSize:10 bold:NO]];
        UIButton *stream = [UIButton buttonWithType:UIButtonTypeCustom];
        stream.frame = CGRectMake(216, 4, 36, 36);
        stream.layer.cornerRadius = 10;
        stream.backgroundColor = hoStreamMode ? [UIColor colorWithRed:1.0 green:0.24 blue:0.28 alpha:1] : [UIColor colorWithWhite:0.5 alpha:0.25];
        [stream setTitle:hoStreamMode ? @"ON" : @"OFF" forState:UIControlStateNormal];
        [stream setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        stream.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        [stream addTarget:self action:@selector(toggleStreamMode) forControlEvents:UIControlEventTouchUpInside];
        [streamRow addSubview:stream];

        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Độ trong suốt menu", @"Menu opacity", @"菜单透明度") frame:CGRectMake(x, 184, 180, 16) fontSize:11 bold:YES]];
        UILabel *alphaValue = [self labelWithText:[NSString stringWithFormat:@"%.2f", hoMenuAlpha] frame:CGRectMake(x + 226, 184, 44, 16) fontSize:11 bold:YES];
        alphaValue.tag = HO_ALPHA_LABEL_TAG;
        [panel.contentView addSubview:alphaValue];
        UISlider *alphaSlider = [[UISlider alloc] initWithFrame:CGRectMake(x, 204, w, 24)];
        alphaSlider.minimumValue = 0.0;
        alphaSlider.maximumValue = 1.0;
        alphaSlider.value = hoMenuAlpha;
        alphaSlider.tintColor = accent;
        [alphaSlider addTarget:self action:@selector(alphaChanged:) forControlEvents:UIControlEventValueChanged];
        [panel.contentView addSubview:alphaSlider];

        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Kích cỡ menu", @"Menu size", @"菜单尺寸") frame:CGRectMake(x, 240, 180, 16) fontSize:11 bold:YES]];
        UILabel *sizeValue = [self labelWithText:[NSString stringWithFormat:@"%.2f", hoMenuScale] frame:CGRectMake(x + 226, 240, 44, 16) fontSize:11 bold:YES];
        sizeValue.tag = HO_SIZE_LABEL_TAG;
        [panel.contentView addSubview:sizeValue];
        UISlider *sizeSlider = [[UISlider alloc] initWithFrame:CGRectMake(x, 260, w, 24)];
        sizeSlider.minimumValue = 0.10;
        sizeSlider.maximumValue = 1.0;
        sizeSlider.value = hoMenuScale;
        sizeSlider.tintColor = accent;
        [sizeSlider addTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];
        [panel.contentView addSubview:sizeSlider];

        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Ngôn ngữ", @"Language", @"语言") frame:CGRectMake(x, 296, 180, 16) fontSize:11 bold:YES]];
        UISegmentedControl *language = [[UISegmentedControl alloc] initWithItems:@[@"VI", @"EN", @"ZH"]];
        language.frame = CGRectMake(x, 316, w, 30);
        language.selectedSegmentIndex = hoLanguage;
        language.tintColor = accent;
        if (@available(iOS 13.0, *)) {
            language.selectedSegmentTintColor = accent;
        }
        [language addTarget:self action:@selector(languageChanged:) forControlEvents:UIControlEventValueChanged];
        [panel.contentView addSubview:language];

        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"Màu menu", @"Menu color", @"菜单颜色") frame:CGRectMake(x, 358, 180, 16) fontSize:11 bold:YES]];
        NSArray<UIColor *> *swatches = @[
            [UIColor colorWithRed:0.18 green:0.78 blue:0.95 alpha:1],
            [UIColor colorWithRed:1.0 green:0.32 blue:0.36 alpha:1],
            [UIColor colorWithRed:0.66 green:0.42 blue:0.98 alpha:1],
            [UIColor colorWithRed:0.30 green:0.86 blue:0.52 alpha:1],
            [UIColor colorWithRed:1.0 green:0.70 blue:0.22 alpha:1]
        ];
        for (NSInteger index = 0; index < swatches.count; index++) {
            UIButton *swatch = [UIButton buttonWithType:UIButtonTypeCustom];
            swatch.frame = CGRectMake(x + index * 46, 380, 34, 34);
            swatch.tag = index;
            swatch.layer.cornerRadius = 17;
            swatch.backgroundColor = swatches[index];
            swatch.layer.borderWidth = index == hoAccentColorIndex ? 3.0 : 0.5;
            swatch.layer.borderColor = index == hoAccentColorIndex ? [self textColor].CGColor : [UIColor clearColor].CGColor;
            [swatch addTarget:self action:@selector(selectColor:) forControlEvents:UIControlEventTouchUpInside];
            [panel.contentView addSubview:swatch];
        }

        [panel.contentView addSubview:[self buttonWithTitle:HOLocalized(@"Thu thành icon", @"Minimize", @"缩小为图标") frame:CGRectMake(x, 430, w, 38) action:@selector(minimize) target:self]];
        [panel.contentView addSubview:[self labelWithText:HOLocalized(@"☾ Dark   ☀ Light", @"☾ Dark   ☀ Light", @"☾ 深色   ☀ 浅色") frame:CGRectMake(x, 480, w, 16) fontSize:10 bold:NO]];
    }

    [panel.contentView addSubview:[self labelWithText:@"v6 · Anonymous" frame:CGRectMake(x, 624, w, 14) fontSize:10 bold:NO]];
    panel.transform = CGAffineTransformMakeScale(hoMenuScale, hoMenuScale);
    return panel;
}

+ (void)change:(HOSwitch *)sender {
    HOApplyToggle((HOToggle)sender.hoIndex, sender.isOn);
    [self show];
}

+ (void)allOn {
    for (NSInteger index = 0; index < HOToggleCount; index++) {
        HOApplyToggle((HOToggle)index, YES);
    }
    [self show];
}

+ (void)allOff {
    for (NSInteger index = 0; index < HOToggleCount; index++) {
        HOApplyToggle((HOToggle)index, NO);
    }
    [self show];
}

+ (UIView *)menuPanel {
    for (UIView *view in hoMenuWindow.subviews.copy) {
        if (view.tag != HO_ICON_TAG) {
            return view;
        }
    }
    return nil;
}

+ (void)showFunctions {
    hoTab = 0;
    [self show];
}

+ (void)showSettings {
    hoTab = 1;
    [self show];
}

+ (void)toggleStreamMode {
    hoStreamMode = !hoStreamMode;
    [self show];
}

+ (void)alphaChanged:(UISlider *)slider {
    hoMenuAlpha = slider.value;
    hoMenuWindow.alpha = hoMenuAlpha;
    UILabel *value = (UILabel *)[hoMenuWindow viewWithTag:HO_ALPHA_LABEL_TAG];
    value.text = [NSString stringWithFormat:@"%.2f", hoMenuAlpha];
}

+ (void)sizeChanged:(UISlider *)slider {
    hoMenuScale = slider.value;
    hoPinchStartScale = hoMenuScale;
    UIView *panel = [self menuPanel];
    panel.transform = CGAffineTransformMakeScale(hoMenuScale, hoMenuScale);
    UILabel *value = (UILabel *)[hoMenuWindow viewWithTag:HO_SIZE_LABEL_TAG];
    value.text = [NSString stringWithFormat:@"%.2f", hoMenuScale];
}

+ (void)languageChanged:(UISegmentedControl *)control {
    hoLanguage = control.selectedSegmentIndex;
    [self show];
}

+ (void)selectColor:(UIButton *)button {
    hoAccentColorIndex = button.tag;
    [self show];
}

+ (void)useDarkTheme {
    hoTheme = 0;
    [self show];
}

+ (void)useLightTheme {
    hoTheme = 1;
    [self show];
}

+ (void)closePanel {
    [self minimize];
}

+ (void)hidePanelOnly {
    if (!hoMenuWindow) {
        return;
    }
    UIView *panel = [self menuPanel];
    [panel removeFromSuperview];
    if (!hoIconVisible) {
        hoMenuWindow.hidden = YES;
    }
}

+ (void)minimize {
    if (!hoMenuWindow) {
        return;
    }
    UIView *panel = nil;
    for (UIView *view in hoMenuWindow.subviews.copy) {
        if (view.tag != HO_ICON_TAG) {
            panel = view;
            break;
        }
    }
    if (!panel) {
        return;
    }
    UIButton *icon = [self floatingIcon];
    CGPoint target = [self floatingIconCenter];
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.12 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        panel.center = target;
        panel.transform = CGAffineTransformMakeScale(0.12, 0.12);
        panel.alpha = 0.0;
        panel.layer.cornerRadius = HO_ICON_SIZE / 2;
    } completion:^(BOOL finished) {
        [panel removeFromSuperview];
        icon.center = target;
        icon.alpha = 0.0;
        icon.transform = CGAffineTransformMakeScale(0.25, 0.25);
        [hoMenuWindow addSubview:icon];
        hoIconVisible = YES;
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.62 initialSpringVelocity:0.2 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            icon.alpha = 1.0;
            icon.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

+ (void)restore {
    if (!hoMenuWindow) {
        [self show];
        return;
    }
    UIButton *icon = nil;
    for (UIView *view in hoMenuWindow.subviews.copy) {
        if (view.tag == HO_ICON_TAG && [view isKindOfClass:UIButton.class]) {
            icon = (UIButton *)view;
            break;
        }
    }
    if (!icon) {
        [self show];
        return;
    }
    UIView *panel = [self buildPanel];
    panel.center = icon.center;
    panel.alpha = 0.0;
    panel.transform = CGAffineTransformMakeScale(0.18, 0.18);
    [icon removeFromSuperview];
    [hoMenuWindow addSubview:panel];
    hoIconVisible = NO;
    CGPoint target = [self menuCenter];
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.16 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        panel.center = target;
        panel.alpha = 1.0;
        panel.transform = CGAffineTransformMakeScale(hoMenuScale, hoMenuScale);
    } completion:nil];
}

+ (void)resetZoom {
    hoMenuScale = 1.0;
    hoPinchStartScale = 1.0;
    if (!hoMenuWindow) {
        return;
    }
    for (UIView *view in hoMenuWindow.subviews.copy) {
        if (view.tag == HO_ICON_TAG) {
            continue;
        }
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.1 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            view.center = [self menuCenter];
            view.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

+ (void)close {
    [self hide];
}

@end

static void HOInstallGesture(void) {
    if (!hoGesture) {
        hoGestureTarget = [HOGestureTarget new];
        hoGesture = [[UITapGestureRecognizer alloc] initWithTarget:hoGestureTarget action:@selector(handleTap:)];
        hoGesture.numberOfTouchesRequired = 3;
        hoGesture.numberOfTapsRequired = 1;
        hoGesture.cancelsTouchesInView = NO;
        hoGesture.delaysTouchesBegan = NO;
        hoGesture.delaysTouchesEnded = NO;
        hoGesture.delegate = hoGestureTarget;
    }
    [HOMenu installGesture];
}

__attribute__((constructor)) static void HOEntry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hoBlockObservers = [NSMutableArray array];
        hoTargetObservers = [NSMutableArray array];
        hoScriptControllers = [NSHashTable weakObjectsHashTable];
        hoHookedMethods = [NSMutableSet set];
        hoPluginOriginals = [NSMutableDictionary dictionary];
        hoLifecycleOriginals = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            if (hoStreamMode) {
                [HOMenu hidePanelOnly];
            }
        }];
        HOHookNotificationCenter();
        HOHookWebView();
        HOHookPlugins();
        HOHookLifecycleDelegates();
        HOHookAlerts();
        dispatch_async(dispatch_get_main_queue(), ^{
            HOInstallGesture();
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            HOInstallGesture();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            HOInstallGesture();
        }];
    });
}
