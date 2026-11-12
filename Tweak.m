// C18PowerMenu - power menu for ControlCenter18 (iOS 16 / 17, roothide)
//
// Same approach as CCBorder's top actions button: a plain UIButton carrying a
// UIMenu built from UIActions, with showsMenuAsPrimaryAction enabled. UIKit
// renders the menu itself, anchored to the button, so there is no custom card
// and no dimming overlay of our own. The presentPowerDownTransientOverlay hook
// re-installs the button and fires its primary action on the CC long press.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <fcntl.h>

extern char **environ;

typedef void (*PresentIMP)(id, SEL);

typedef NS_ENUM(NSInteger, C18PowerAction) {
    C18PowerActionSoftRespring = 0,   // 快速注销
    C18PowerActionHardRespring,       // 强制注销
    C18PowerActionRestartDesktop,     // 重启桌面
    C18PowerActionSafeMode,           // 安全模式
    C18PowerActionUserspaceReboot,    // 重启空间
    C18PowerActionReboot,             // 重启设备
    C18PowerActionShutdown,           // 设备关机
};

static PresentIMP g_orig[16];
static Class g_cls[16];
static int g_count = 0;
static UIButton *g_menuButton = nil;

#pragma mark - jbroot / spawn

static NSString *C18JBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)&C18JBRoot, &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            NSRange r = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
            if (r.location != NSNotFound) root = [path substringToIndex:r.location];
        }
        if (!root) root = @"/var/jb";
    });
    return root;
}

static NSString *C18Tool(NSString *relative) {
    NSString *full = [C18JBRoot() stringByAppendingPathComponent:relative];
    if ([[NSFileManager defaultManager] fileExistsAtPath:full]) return full;
    return relative;
}

static void C18Spawn(NSString *relative, NSArray<NSString *> *args) {
    NSString *path = C18Tool(relative);
    const char *argv[16];
    int i = 0;
    argv[i++] = strdup(path.UTF8String);
    for (NSString *arg in args) {
        if (i >= 15) break;
        argv[i++] = strdup(arg.UTF8String);
    }
    argv[i] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid = 0;
    if (posix_spawn(&pid, path.UTF8String, &actions, NULL, (char *const *)argv, environ) == 0 && pid > 0) {
        waitpid(pid, NULL, WNOHANG);
    }
    posix_spawn_file_actions_destroy(&actions);
}

#pragma mark - actions

static void C18RunAction(C18PowerAction action) {
    switch (action) {
        case C18PowerActionSoftRespring:   C18Spawn(@"/usr/bin/sbreload", @[]); break;
        case C18PowerActionHardRespring:   C18Spawn(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]); break;
        case C18PowerActionRestartDesktop: C18Spawn(@"/usr/bin/killall", @[@"SpringBoard"]); break;
        case C18PowerActionSafeMode:       C18Spawn(@"/usr/bin/killall", @[@"-SEGV", @"SpringBoard"]); break;
        case C18PowerActionUserspaceReboot:C18Spawn(@"/bin/launchctl", @[@"reboot", @"userspace"]); break;
        case C18PowerActionReboot:         C18Spawn(@"/usr/bin/reboot", @[]); break;
        case C18PowerActionShutdown: {
            Class mgr = NSClassFromString(@"SBLockScreenManager");
            id inst = nil;
            SEL sharedSel = NSSelectorFromString(@"sharedInstanceIfExists");
            if ([mgr respondsToSelector:sharedSel]) {
                inst = ((id (*)(id, SEL))objc_msgSend)(mgr, sharedSel);
            }
            SEL sel = NSSelectorFromString(@"presentPowerDownTransientOverlay");
            if (inst && [inst respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(inst, sel);
            }
            break;
        }
    }
}

#pragma mark - menu

static UIImage *C18Glyph(NSString *name) {
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:name withConfiguration:cfg];
}

static UIMenu *C18BuildMenu(void) {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];

    NSArray<NSDictionary *> *items = @[
        @{@"title": @"快速注销", @"glyph": @"circle.dashed",                     @"action": @(C18PowerActionSoftRespring)},
        @{@"title": @"强制注销", @"glyph": @"circle.dashed.inset.filled",        @"action": @(C18PowerActionHardRespring)},
        @{@"title": @"重启桌面", @"glyph": @"rectangle.on.rectangle",            @"action": @(C18PowerActionRestartDesktop)},
        @{@"title": @"安全模式", @"glyph": @"shield.lefthalf.filled",            @"action": @(C18PowerActionSafeMode)},
        @{@"title": @"重启空间", @"glyph": @"arrow.clockwise.circle",            @"action": @(C18PowerActionUserspaceReboot)},
        @{@"title": @"重启设备", @"glyph": @"exclamationmark.arrow.circlepath",  @"action": @(C18PowerActionReboot)},
        @{@"title": @"设备关机", @"glyph": @"power",                             @"action": @(C18PowerActionShutdown)},
    ];

    for (NSDictionary *item in items) {
        C18PowerAction act = (C18PowerAction)[item[@"action"] integerValue];
        UIAction *action = [UIAction actionWithTitle:item[@"title"]
                                                image:C18Glyph(item[@"glyph"])
                                           identifier:item[@"title"]
                                              handler:^(__unused UIAction *a) {
            C18RunAction(act);
        }];
        [children addObject:action];
    }

    UIAction *cancel = [UIAction actionWithTitle:@"取消操作"
                                            image:C18Glyph(@"trash")
                                       identifier:@"cancel"
                                          handler:^(__unused UIAction *a) {}];
    if (@available(iOS 15.0, *)) {
        cancel.attributes = UIMenuElementAttributesDestructive;
    }
    [children addObject:cancel];

    return [UIMenu menuWithTitle:@"" children:children];
}

#pragma mark - power button overlay

static char kC18MenuButtonKey;

static UIView *C18FindPowerView(UIView *view) {
    NSString *lower = NSStringFromClass([view class]).lowercaseString;
    BOOL looksLikePower = [lower containsString:@"power"] || [lower containsString:@"c18power"];
    if (looksLikePower && view.window) {
        CGSize s = view.bounds.size;
        if (s.width >= 24 && s.height >= 24) return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *hit = C18FindPowerView(sub);
        if (hit) return hit;
    }
    return nil;
}

static UIView *C18RootForScan(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIView *root = w.rootViewController.view;
        if (!root) continue;
        UIView *hit = C18FindPowerView(root);
        if (hit) return hit;
    }
    return nil;
}

static void C18InstallMenuButton(UIView *powerView) {
    if (!powerView) return;
    UIButton *existing = objc_getAssociatedObject(powerView, &kC18MenuButtonKey);
    if (existing) { g_menuButton = existing; return; }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = powerView.bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    button.backgroundColor = [UIColor clearColor];
    button.menu = C18BuildMenu();
    button.showsMenuAsPrimaryAction = YES;
    button.accessibilityLabel = @"电源";

    [powerView addSubview:button];
    objc_setAssociatedObject(powerView, &kC18MenuButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    g_menuButton = button;
}

static void C18OpenMenu(void) {
    if (!g_menuButton) C18InstallMenuButton(C18RootForScan());
    if (!g_menuButton) return;

    // The button already carries the menu; fire its primary action so UIKit
    // presents the system menu anchored to the power button.
    [g_menuButton sendActionsForControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - presentPowerDownTransientOverlay hook

static PresentIMP C18OriginalFor(id object) {
    for (int i = 0; i < g_count; i++) {
        if ([object isKindOfClass:g_cls[i]]) return g_orig[i];
    }
    return NULL;
}

static void C18PowerMenuHook(id self, SEL cmd) {
    PresentIMP original = C18OriginalFor(self);

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            C18PowerMenuHook(self, cmd);
        });
        return;
    }

    @try {
        C18OpenMenu();
    } @catch (__unused NSException *exception) {
        if (original) original(self, cmd);
    }
}

static BOOL C18ClassImplements(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static void C18InstallPowerHook(void) {
    SEL sel = sel_registerName("presentPowerDownTransientOverlay");
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(classes, num);

    for (int i = 0; i < num && g_count < 16; i++) {
        Class cls = classes[i];
        if (!C18ClassImplements(cls, sel)) continue;

        Method method = class_getInstanceMethod(cls, sel);
        if (!method) continue;

        IMP original = method_getImplementation(method);
        if (original == (IMP)C18PowerMenuHook) continue;

        g_cls[g_count] = cls;
        g_orig[g_count] = (PresentIMP)original;
        g_count++;
        method_setImplementation(method, (IMP)C18PowerMenuHook);
    }

    free(classes);
}

#pragma mark - CC overlay hook (re-install button after CC appears)

static void (*g_origViewDidAppear)(id, SEL, BOOL) = NULL;

static void C18ViewDidAppearHook(id self, SEL cmd, BOOL animated) {
    if (g_origViewDidAppear) g_origViewDidAppear(self, cmd, animated);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        C18InstallMenuButton(C18RootForScan());
    });
}

static void C18InstallOverlayHook(void) {
    Class cls = NSClassFromString(@"CCUIModularControlCenterOverlayViewController");
    if (!cls) return;

    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP orig = method_getImplementation(m);
    if (orig == (IMP)C18ViewDidAppearHook) return;
    g_origViewDidAppear = (void (*)(id, SEL, BOOL))orig;
    method_setImplementation(m, (IMP)C18ViewDidAppearHook);
}

__attribute__((constructor)) static void C18PowerMenuInit(void) {
    @autoreleasepool {
        C18InstallPowerHook();
        C18InstallOverlayHook();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            C18InstallMenuButton(C18RootForScan());
        });

        if (g_count == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_count == 0) C18InstallPowerHook();
            });
        }
    }
}
