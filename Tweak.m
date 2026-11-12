// C18PowerMenu - power menu for ControlCenter18 (iOS 16 / 17, roothide)
//
// Menu is a plain UIMenu of UIActions (same as CCBorder's top actions button),
// rendered by UIKit itself as a light rounded card: text left, SF symbol right,
// over its own blurred backdrop. Long press on CC18's power glyph ends up in
// presentPowerDownTransientOverlay, which we keep hooking. A fresh
// UIContextMenuInteraction presents the card right under that glyph; only when
// it really accepts the request do we drop the original call.

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

static __weak UIView *g_overlayView = nil;

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

#pragma mark - context menu

// UIContextMenuInteraction renders UIMenu exactly like a system card: text on
// the left, SF symbol on the right, over its own blurred backdrop.
static BOOL g_menuOpen = NO;
static NSTimeInterval g_menuClosedAt = 0;

@interface C18MenuDelegate : NSObject <UIContextMenuInteractionDelegate>
@end

@implementation C18MenuDelegate

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
   willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                       animator:(id<UIContextMenuInteractionAnimating>)animator {
    g_menuOpen = YES;
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
      willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                       animator:(id<UIContextMenuInteractionAnimating>)animator {
    g_menuOpen = NO;
    g_menuClosedAt = [NSDate timeIntervalSinceReferenceDate];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggestedActions) {
        return C18BuildMenu();
    }];
}

@end

static C18MenuDelegate *g_delegate = nil;
static UIContextMenuInteraction *g_interaction = nil;
static UIView *g_anchorView = nil;

// CC18 draws its power icon in a small view whose class name mentions "power"
// (C18PowerGlyphView and friends). Look that view up directly instead of
// guessing from the left edge, which also keeps it correct in landscape.
static UIView *C18FindPowerView(UIView *view) {
    NSString *cls = NSStringFromClass([view class]).lowercaseString;
    BOOL nameHit = [cls containsString:@"c18power"] || [cls containsString:@"powerglyph"] || [cls containsString:@"power"];

    if (nameHit && view.window) {
        CGSize s = view.bounds.size;
        if (s.width >= 14 && s.width <= 100 && s.height >= 14 && s.height <= 100) return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *hit = C18FindPowerView(sub);
        if (hit) return hit;
    }
    return nil;
}

static CGRect C18GlyphRect(UIView *overlay) {
    UIView *power = C18FindPowerView(overlay);
    if (power) return [power convertRect:power.bounds toView:overlay];

    // Fallback: anchored to the top trailing corner, so landscape stays right.
    CGFloat top = overlay.safeAreaInsets.top;
    if (top <= 0 && overlay.window) top = overlay.window.safeAreaInsets.top;
    CGFloat x = overlay.bounds.size.width - 64;
    CGFloat y = MAX(top, 8) + 6;
    return CGRectMake(x, y, 40, 40);
}

static void C18AnchorViewFor(UIView *overlay) {
    CGRect glyph = C18GlyphRect(overlay);
    CGRect frame = CGRectInset(glyph, -8, -8);

    if (!g_anchorView || g_anchorView.superview != overlay) {
        [g_anchorView removeFromSuperview];
        g_anchorView = [[UIView alloc] initWithFrame:frame];
        g_anchorView.backgroundColor = [UIColor clearColor];
        g_anchorView.userInteractionEnabled = NO;
        g_anchorView.alpha = 0.01;
        [overlay addSubview:g_anchorView];
    } else {
        g_anchorView.frame = frame;
    }
}

static UIView *C18OverlayView(void) {
    if (g_overlayView && g_overlayView.window) return g_overlayView;

    Class cc = NSClassFromString(@"CCUIModularControlCenterOverlayViewController");
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        id vc = w.rootViewController;
        if (![vc isKindOfClass:cc]) continue;
        UIView *view = ((UIViewController *)vc).view;
        if (view.window) {
            g_overlayView = view;
            return view;
        }
    }
    return nil;
}

// Returns YES only when the interaction really presents the card menu.
static BOOL C18PresentMenu(NSString **outReason) {
    UIView *overlay = C18OverlayView();
    if (!overlay) {
        if (outReason) *outReason = @"no overlay";
        return NO;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_delegate = [C18MenuDelegate new];
    });

    C18AnchorViewFor(overlay);

    // A reused interaction breaks on the second presentation (UIKit is still
    // dismissing the previous one), so every press gets a fresh one.
    if (g_interaction) {
        [g_interaction.view removeInteraction:g_interaction];
        g_interaction = nil;
    }
    g_interaction = [[UIContextMenuInteraction alloc] initWithDelegate:g_delegate];
    [g_anchorView addInteraction:g_interaction];

    static NSArray<NSString *> *selectors = nil;
    static dispatch_once_t selOnce;
    dispatch_once(&selOnce, ^{
        selectors = @[@"_presentMenuAtLocation:", @"_presentMenuAtLocation:animated:"];
    });

    SEL presentSel = NULL;
    for (NSString *name in selectors) {
        SEL candidate = NSSelectorFromString(name);
        if ([g_interaction respondsToSelector:candidate]) { presentSel = candidate; break; }
    }
    if (!presentSel) {
        if (outReason) *outReason = @"no present selector";
        return NO;
    }

    // Just under the glyph: the card opens downwards from the button.
    CGPoint point = CGPointMake(CGRectGetMidX(g_anchorView.bounds), CGRectGetMaxY(g_anchorView.bounds) + 2);
    {
        CGRect glyph = C18GlyphRect(overlay);
        NSString *log = [NSString stringWithFormat:@"glyph=%.1f,%.1f,%.1f,%.1f anchor=%.1f,%.1f point=%.1f,%.1f overlay=%.1fx%.1f\n",
                         glyph.origin.x, glyph.origin.y, glyph.size.width, glyph.size.height,
                         g_anchorView.frame.origin.x, g_anchorView.frame.origin.y,
                         point.x, point.y,
                         overlay.bounds.size.width, overlay.bounds.size.height];
        [log writeToFile:@"/var/mobile/Library/C18PowerMenu-anchor.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    if (sel_isEqual(presentSel, NSSelectorFromString(@"_presentMenuAtLocation:animated:"))) {
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(g_interaction, presentSel, point, YES);
    } else {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(g_interaction, presentSel, point);
    }
    if (outReason) *outReason = nil;
    return YES;
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

    if (g_menuOpen) return;                                                        // already showing
    if ([NSDate timeIntervalSinceReferenceDate] - g_menuClosedAt < 0.45) return;   // still animating out

    NSString *reason = nil;
    BOOL presented = NO;
    @try {
        presented = C18PresentMenu(&reason);
    } @catch (__unused NSException *exception) {
        presented = NO;
        reason = @"exception";
        if (g_interaction) {
            [g_interaction.view removeInteraction:g_interaction];
            g_interaction = nil;
        }
    }

    if (!presented && original) {
        original(self, cmd);
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

#pragma mark - CC overlay hook

static void (*g_origViewDidAppear)(id, SEL, BOOL) = NULL;

static void C18ViewDidAppearHook(id self, SEL cmd, BOOL animated) {
    if (g_origViewDidAppear) g_origViewDidAppear(self, cmd, animated);

    if ([self isKindOfClass:[UIViewController class]]) {
        g_overlayView = ((UIViewController *)self).view;
    }
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

        if (g_count == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_count == 0) C18InstallPowerHook();
            });
        }
    }
}
