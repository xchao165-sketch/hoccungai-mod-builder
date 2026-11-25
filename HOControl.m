#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

@class HOSwitch;

@interface HOMenu : NSObject
+ (void)show;
+ (void)hide;
+ (void)installGesture;
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

static BOOL hoStates[HOToggleCount] = {YES, YES, YES, YES, YES};
static IMP HOOrigAddObserverBlock;
static IMP HOOrigAddObserverTarget;
static IMP HOOrigAddScriptHandler;
static IMP HOOrigRemoveScriptHandler;
static IMP HOOrigEvaluateJS;
static IMP HOOrigPresentVC;
static NSMutableDictionary<NSString *, NSValue *> *hoPluginOriginals;
static NSMutableArray<NSMutableDictionary *> *hoBlockObservers;
static NSMutableArray<NSMutableDictionary *> *hoTargetObservers;
static NSHashTable<WKUserContentController *> *hoScriptControllers;
static NSMutableSet<NSValue *> *hoHookedMethods;
static UITapGestureRecognizer *hoGesture;
static id hoGestureTarget;
static UIWindow *hoMenuWindow;
static NSTimeInterval hoLastTapTime = 0;

static BOOL HOEnabled(HOToggle toggle) {
    return hoStates[toggle];
}

static NSSet<NSString *> *HOScreenshotNotificationNames(void) {
    return [NSSet setWithObjects:UIApplicationUserDidTakeScreenshotNotification, UIScreenCapturedDidChangeNotification, nil];
}

static NSSet<NSString *> *HORecordNotificationNames(void) {
    return [NSSet setWithObjects:UIScreenCapturedDidChangeNotification, nil];
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

static void HOApplyToggle(HOToggle toggle, BOOL enabled) {
    hoStates[toggle] = enabled;
    if (!enabled && toggle == HOToggleScreenshot) {
        HORemoveProtectionViews();
        HORemoveBlockObserversForNames(HOScreenshotNotificationNames());
        HORemoveTargetObserversForNames(HOScreenshotNotificationNames());
    }
    if (!enabled && toggle == HOToggleRecord) {
        HORemoveBlockObserversForNames(HORecordNotificationNames());
        HORemoveTargetObserversForNames(HORecordNotificationNames());
    }
    if (!enabled && toggle == HOToggleLogout) {
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
            allowed = HOEnabled(HOToggleScreenshot);
        } else if ([HORecordNotificationNames() containsObject:name]) {
            allowed = HOEnabled(HOToggleRecord);
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
            allowed = HOEnabled(HOToggleScreenshot);
        } else if ([HORecordNotificationNames() containsObject:name]) {
            allowed = HOEnabled(HOToggleRecord);
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
        if (!HOEnabled(HOToggleLogout) && [HOLogoutHandlerNames() containsObject:name]) {
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
        if (!HOEnabled(HOToggleSessionJS)) {
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
            if (!HOEnabled(HOToggleScreenshot) && HOIsScreenshotMethod(method)) {
                HOAnswer(result, @YES);
                return;
            }
            if ([method isEqualToString:@"isPreventScreenshotEnabled"] && !HOEnabled(HOToggleScreenshot)) {
                HOAnswer(result, @NO);
                return;
            }
            if (!HOEnabled(HOToggleRecord) && HOIsRecordMethod(method)) {
                HOAnswer(result, @YES);
                return;
            }
            if ([method isEqualToString:@"isPreventScreenRecordingEnabled"] && !HOEnabled(HOToggleRecord)) {
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
        if (!HOEnabled(HOToggleLockWarning) && HOLooksLikeLockWarning(viewController)) {
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
    if (gesture.state != UIGestureRecognizerStateEnded) {
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

+ (void)installGesture {
    UIWindow *window = [self keyWindow];
    if (!window || !hoGesture) {
        return;
    }
    if (hoGesture.view && hoGesture.view != window) {
        [hoGesture.view removeGestureRecognizer:hoGesture];
    }
    if (![window.gestureRecognizers containsObject:hoGesture]) {
        [window addGestureRecognizer:hoGesture];
    }
}

+ (void)show {
    if (!hoMenuWindow) {
        hoMenuWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        hoMenuWindow.windowLevel = UIWindowLevelAlert + 100;
        hoMenuWindow.backgroundColor = UIColor.clearColor;
        hoMenuWindow.hidden = YES;
    }
    for (UIView *view in hoMenuWindow.subviews.copy) {
        [view removeFromSuperview];
    }
    UIView *panel = [self buildPanel];
    [hoMenuWindow addSubview:panel];
    hoMenuWindow.hidden = NO;
}

+ (void)hide {
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
    panel.frame = CGRectMake((UIScreen.mainScreen.bounds.size.width - 330) / 2, (UIScreen.mainScreen.bounds.size.height - 430) / 2, 330, 430);
    panel.layer.cornerRadius = 18;
    panel.clipsToBounds = YES;
    panel.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];

    [panel.contentView addSubview:[self labelWithText:@"MENU ĐIỀU KHIỂN" frame:CGRectMake(18, 16, 230, 30) fontSize:19 bold:YES]];
    [panel.contentView addSubview:[self labelWithText:@"Bật = giữ bảo vệ như gốc" frame:CGRectMake(18, 46, 250, 20) fontSize:12 bold:NO]];

    UIButton *close = [self buttonWithTitle:@"Đóng" frame:CGRectMake(264, 16, 52, 30) action:@selector(close) target:self];
    [panel.contentView addSubview:close];

    NSArray<NSString *> *titles = @[@"Chặn chụp màn hình", @"Chặn quay màn hình", @"Log thoát/logout", @"Session/device JS", @"Lock warning"];
    for (NSInteger index = 0; index < titles.count; index++) {
        CGFloat y = 88 + index * 48;
        [panel.contentView addSubview:[self labelWithText:titles[index] frame:CGRectMake(18, y, 220, 30) fontSize:15 bold:NO]];
        HOSwitch *toggle = [[HOSwitch alloc] initWithFrame:CGRectMake(254, y - 2, 51, 31)];
        toggle.hoIndex = index;
        toggle.on = HOEnabled((HOToggle)index);
        [toggle addTarget:self action:@selector(change:) forControlEvents:UIControlEventValueChanged];
        [panel.contentView addSubview:toggle];
    }

    [panel.contentView addSubview:[self buttonWithTitle:@"Bật tất cả" frame:CGRectMake(18, 344, 140, 40) action:@selector(allOn) target:self]];
    [panel.contentView addSubview:[self buttonWithTitle:@"Tắt tất cả" frame:CGRectMake(172, 344, 140, 40) action:@selector(allOff) target:self]];
    [panel.contentView addSubview:[self labelWithText:@"Chỉ áp dụng trong phiên hiện tại" frame:CGRectMake(18, 398, 294, 18) fontSize:12 bold:NO]];
    return panel;
}

+ (void)change:(HOSwitch *)sender {
    HOApplyToggle((HOToggle)sender.hoIndex, sender.isOn);
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
        HOHookNotificationCenter();
        HOHookWebView();
        HOHookPlugins();
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
