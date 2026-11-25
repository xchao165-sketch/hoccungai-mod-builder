#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

@class HOSwitch;

#define HO_MENU_TAG 981372
#define HO_ICON_TAG 981373
#define HO_PANEL_WIDTH 340.0
#define HO_PANEL_HEIGHT 540.0
#define HO_ICON_SIZE 56.0

static NSString *const HOIconImageURL = @"https://imgs.search.brave.com/Gll420MeLwA4SVJxJEp_QrJQbBsytXon6-FLTXpSt08/rs:fit:860:0:0:0/g:ce/aHR0cHM6Ly9pbWFn/ZXMucGV4ZWxzLmNv/bS9waG90b3MvMzg4/MDA0OS9wZXhlbHMt/cGhvdG8tMzg4MDA0/OS5qcGVnP2NzPXRp/bnlzcmdiJmRwcj0x/Jnc9NTAw";

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
static NSTimeInterval hoLastTapTime = 0;

static BOOL HOUnblocked(HOToggle toggle) {
    return hoStates[toggle];
}

static BOOL HOProtectionEnabled(HOToggle toggle) {
    return !hoStates[toggle];
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
    hoMenuScale = MIN(MAX(scale, 0.55), 1.7);
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
    [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
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
    }] resume];
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
        hoMenuWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
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

+ (UILabel *)labelWithText:(NSString *)text frame:(CGRect)frame fontSize:(CGFloat)size bold:(BOOL)bold {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = UIColor.clearColor;
    label.numberOfLines = 2;
    return label;
}

+ (UIButton *)buttonWithTitle:(NSString *)title frame:(CGRect)frame action:(SEL)action target:(id)target {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = 10;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

+ (UIView *)buildPanel {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:effect];
    panel.frame = CGRectMake(0, 0, HO_PANEL_WIDTH, HO_PANEL_HEIGHT);
    panel.layer.cornerRadius = 22;
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    panel.clipsToBounds = YES;
    panel.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];

    UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, HO_PANEL_WIDTH, 3)];
    accent.backgroundColor = [UIColor colorWithRed:0.18 green:0.78 blue:0.95 alpha:1];
    [panel.contentView addSubview:accent];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    [panel addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    pinch.cancelsTouchesInView = NO;
    [panel addGestureRecognizer:pinch];

    [panel.contentView addSubview:[self labelWithText:@"MOD MENU BY ANONYMOUS" frame:CGRectMake(18, 15, 260, 26) fontSize:17 bold:YES]];
    [panel.contentView addSubview:[self labelWithText:@"TẮT = chưa bảo vệ   BẬT = đang bảo vệ" frame:CGRectMake(18, 42, 290, 16) fontSize:11 bold:NO]];

    UIButton *close = [self buttonWithTitle:@"Đóng" frame:CGRectMake(282, 14, 44, 28) action:@selector(close) target:self];
    [panel.contentView addSubview:close];

    BOOL anyProtected = NO;
    for (NSInteger index = 0; index < HOToggleCount; index++) {
        if (HOProtectionEnabled((HOToggle)index)) {
            anyProtected = YES;
            break;
        }
    }
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(18, 66, 304, 28)];
    pill.layer.cornerRadius = 14;
    pill.backgroundColor = anyProtected ? [UIColor colorWithRed:0.18 green:0.78 blue:0.95 alpha:0.16] : [UIColor colorWithRed:0.95 green:0.55 blue:0.25 alpha:0.18];
    [panel.contentView addSubview:pill];
    UILabel *pillLabel = [self labelWithText:anyProtected ? @"TRẠNG THÁI: ĐANG BẢO VỆ" : @"TRẠNG THÁI: CHƯA BẢO VỆ" frame:CGRectMake(12, 5, 280, 18) fontSize:12 bold:YES];
    pillLabel.textColor = anyProtected ? [UIColor colorWithRed:0.45 green:0.9 blue:1.0 alpha:1] : [UIColor colorWithRed:1.0 green:0.72 blue:0.42 alpha:1];
    [pill addSubview:pillLabel];

    [panel.contentView addSubview:[self labelWithText:@"BẢO VỆ" frame:CGRectMake(18, 102, 200, 16) fontSize:11 bold:YES]];

    NSArray<NSString *> *titles = @[@"Chụp màn hình", @"Quay màn hình", @"Logout / log", @"Session / device JS", @"Rời bài"];
    for (NSInteger index = 0; index < titles.count; index++) {
        CGFloat y = 124 + index * 48;
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(12, y, 316, 43)];
        row.layer.cornerRadius = 12;
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.055];
        [panel.contentView addSubview:row];

        BOOL rowProtected = HOProtectionEnabled((HOToggle)index);
        UILabel *title = [self labelWithText:titles[index] frame:CGRectMake(14, 4, 220, 18) fontSize:14 bold:YES];
        [row addSubview:title];
        UILabel *detail = [self labelWithText:rowProtected ? @"Đang bảo vệ" : @"Chưa có bảo vệ" frame:CGRectMake(14, 23, 220, 14) fontSize:11 bold:NO];
        detail.textColor = [UIColor colorWithWhite:0.72 alpha:1];
        [row addSubview:detail];

        HOSwitch *toggle = [[HOSwitch alloc] initWithFrame:CGRectMake(254, 6, 51, 31)];
        toggle.hoIndex = index;
        toggle.on = rowProtected;
        toggle.onTintColor = [UIColor colorWithRed:0.18 green:0.78 blue:0.95 alpha:1];
        toggle.tintColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        toggle.thumbTintColor = UIColor.whiteColor;
        [toggle addTarget:self action:@selector(change:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:toggle];
    }

    [panel.contentView addSubview:[self labelWithText:@"DASHBOARD / CÀI ĐẶT" frame:CGRectMake(18, 370, 220, 16) fontSize:11 bold:YES]];
    [panel.contentView addSubview:[self buttonWithTitle:@"Thu thành icon" frame:CGRectMake(18, 392, 148, 40) action:@selector(minimize) target:self]];
    [panel.contentView addSubview:[self buttonWithTitle:@"Reset zoom" frame:CGRectMake(174, 392, 148, 40) action:@selector(resetZoom) target:self]];
    [panel.contentView addSubview:[self labelWithText:@"Kéo = di chuyển · Chụm = thu phóng" frame:CGRectMake(18, 442, 304, 16) fontSize:11 bold:NO]];
    [panel.contentView addSubview:[self labelWithText:@"Chỉ áp dụng trong phiên hiện tại" frame:CGRectMake(18, 466, 304, 16) fontSize:11 bold:NO]];
    [panel.contentView addSubview:[self labelWithText:@"v4 · Anonymous" frame:CGRectMake(18, 500, 304, 14) fontSize:10 bold:NO]];
    panel.transform = CGAffineTransformMakeScale(hoMenuScale, hoMenuScale);
    return panel;
}

+ (void)change:(HOSwitch *)sender {
    HOApplyToggle((HOToggle)sender.hoIndex, !sender.isOn);
    [self show];
}

+ (void)allOn {
    for (NSInteger index = 0; index < HOToggleCount; index++) {
        HOApplyToggle((HOToggle)index, NO);
    }
    [self show];
}

+ (void)allOff {
    for (NSInteger index = 0; index < HOToggleCount; index++) {
        HOApplyToggle((HOToggle)index, YES);
    }
    [self show];
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
