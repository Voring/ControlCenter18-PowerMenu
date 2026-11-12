// C18PowerMenu - Power menu for ControlCenter18 (iOS 16 / 17, roothide)
// ControlCenter18's power button only reacts to a long press; the hook below is
// that long-press entry point and shows our own menu.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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
    C18PowerActionCancel,             // 取消操作
};

static PresentIMP g_orig[16];
static Class g_cls[16];
static int g_count = 0;
static BOOL g_presenting = NO;

#pragma mark - Path helpers

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
    if (!path) return;

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
    posix_spawn(&pid, path.UTF8String, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
}

static void C18RunAction(C18PowerAction action, PresentIMP original, id target, SEL cmd) {
    switch (action) {
        case C18PowerActionSoftRespring:  C18Spawn(@"/usr/bin/killall", @[@"SpringBoard"]); break;
        case C18PowerActionHardRespring:  C18Spawn(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]); break;
        case C18PowerActionRestartDesktop:C18Spawn(@"/usr/bin/ldrestart", @[]); break;
        case C18PowerActionSafeMode:      C18Spawn(@"/usr/bin/killall", @[@"-SEGV", @"SpringBoard"]); break;
        case C18PowerActionUserspaceReboot: C18Spawn(@"/usr/bin/launchctl", @[@"reboot", @"userspace"]); break;
        case C18PowerActionReboot:        C18Spawn(@"/usr/bin/reboot", @[]); break;
        case C18PowerActionShutdown:      if (original) original(target, cmd); break;
        case C18PowerActionCancel:        break;
    }
}

#pragma mark - Menu model

static NSArray<NSDictionary *> *C18MenuItems(void) {
    return @[
        @{@"title": @"快速注销", @"glyph": @"circle.dashed",              @"action": @(C18PowerActionSoftRespring)},
        @{@"title": @"强制注销", @"glyph": @"circle.dashed.inset.filled",  @"action": @(C18PowerActionHardRespring)},
        @{@"title": @"重启桌面", @"glyph": @"rectangle.on.rectangle",      @"action": @(C18PowerActionRestartDesktop)},
        @{@"title": @"安全模式", @"glyph": @"shield.lefthalf.filled",      @"action": @(C18PowerActionSafeMode)},
        @{@"title": @"重启空间", @"glyph": @"arrow.clockwise.circle",      @"action": @(C18PowerActionUserspaceReboot)},
        @{@"title": @"重启设备", @"glyph": @"exclamationmark.arrow.circlepath", @"action": @(C18PowerActionReboot)},
        @{@"title": @"设备关机", @"glyph": @"power",                       @"action": @(C18PowerActionShutdown)},
        @{@"title": @"取消操作", @"glyph": @"trash",                       @"action": @(C18PowerActionCancel)},
    ];
}

static UIImage *C18Glyph(NSString *name, CGFloat point) {
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:point weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"circle" withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Menu view controller (light card, label left / SF glyph right)

@interface C18MenuViewController : UIViewController
@property (nonatomic, copy) void (^handler)(C18PowerAction);
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, assign) CGRect buttonFrame;
@end

@implementation C18MenuViewController

static const CGFloat kRowHeight = 58.0;
static const CGFloat kSideInset = 18.0;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight];
    self.blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.blur.frame = self.view.bounds;
    self.blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.blur];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:dim];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    [dim addGestureRecognizer:tap];

    NSArray<NSDictionary *> *items = C18MenuItems();
    CGFloat cardWidth = MIN(CGRectGetWidth(self.view.bounds) * 0.66, 280);
    CGFloat cardHeight = kRowHeight * items.count;

    self.card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardWidth, cardHeight)];
    self.card.backgroundColor = [UIColor colorWithWhite:0.96 alpha:0.97];
    self.card.layer.cornerRadius = 20;
    self.card.layer.cornerCurve = kCACornerCurveContinuous;
    self.card.layer.masksToBounds = YES;
    [self.view addSubview:self.card];

    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = items[i];
        C18PowerAction action = (C18PowerAction)[item[@"action"] integerValue];
        BOOL isCancel = (action == C18PowerActionCancel);
        UIColor *tint = isCancel ? [UIColor systemRedColor] : [UIColor blackColor];

        UIControl *row = [[UIControl alloc] initWithFrame:CGRectMake(0, kRowHeight * i, cardWidth, kRowHeight)];
        row.tag = (NSInteger)action;
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(kSideInset, 0, cardWidth - kSideInset * 2 - 34, kRowHeight)];
        label.text = item[@"title"];
        label.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        label.textColor = tint;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:label];

        UIImageView *icon = [[UIImageView alloc] initWithImage:C18Glyph(item[@"glyph"], 20)];
        icon.tintColor = tint;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.frame = CGRectMake(cardWidth - kSideInset - 24, (kRowHeight - 26) / 2, 24, 26);
        icon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [row addSubview:icon];

        if (i + 1 < items.count) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, kRowHeight - 0.5, cardWidth, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
            line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [row addSubview:line];
        }

        [self.card addSubview:row];
    }

    [self layoutCard];
}

- (void)layoutCard {
    CGSize size = self.card.bounds.size;
    CGFloat W = CGRectGetWidth(self.view.bounds);
    CGFloat H = CGRectGetHeight(self.view.bounds);
    CGFloat safeTop = self.view.safeAreaInsets.top;
    CGFloat top, right;
    if (!CGRectIsEmpty(self.buttonFrame)) {
        top = CGRectGetMaxY(self.buttonFrame) + 10;
        right = CGRectGetMaxX(self.buttonFrame);
    } else {
        top = (safeTop > 0 ? safeTop : 44) + 16;
        right = W - 24;
    }
    CGFloat x = right - size.width;
    if (x < 12) x = 12;
    if (x + size.width > W - 12) x = W - 12 - size.width;
    if (top + size.height > H - 24) top = H - 24 - size.height;
    self.card.frame = CGRectMake(x, top, size.width, size.height);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.blur.frame = self.view.bounds;
    [self layoutCard];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)rowTapped:(UIControl *)sender {
    C18PowerAction action = (C18PowerAction)sender.tag;
    void (^handler)(C18PowerAction) = self.handler;
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                handler(action);
            });
        }
    }];
}

@end

#pragma mark - Presentation helpers

static void C18CollectPowerFrame(UIView *view, CGRect *out, int depth) {
    if (!view || depth > 10) return;
    NSString *cls = NSStringFromClass([view class]);
    if ([cls.lowercaseString containsString:@"power"] && view.window) {
        CGRect f = [view.window convertRect:view.bounds fromView:view];
        if (f.size.width > 20 && f.size.height > 20) { *out = f; return; }
    }
    for (UIView *sub in view.subviews) C18CollectPowerFrame(sub, out, depth + 1);
}

static CGRect C18PowerButtonFrame(void) {
    CGRect f = CGRectZero;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        C18CollectPowerFrame(w.rootViewController.view, &f, 0);
        if (!CGRectIsEmpty(f)) break;
    }
    return f;
}

static UIViewController *C18TopViewController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *key = nil;
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow && w.rootViewController) { key = w; break; }
    }
    if (!key) {
        for (UIWindow *w in app.windows) {
            if (w.rootViewController && !w.hidden) { key = w; break; }
        }
    }
    if (!key) return nil;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void C18ShowPowerMenu(id target, SEL cmd, PresentIMP original) {
    if (g_presenting) return;
    @try {
        UIViewController *host = C18TopViewController();

        C18MenuViewController *menu = [[C18MenuViewController alloc] init];
        menu.buttonFrame = C18PowerButtonFrame();
        menu.handler = ^(C18PowerAction action) {
            g_presenting = NO;
            C18RunAction(action, original, target, cmd);
        };

        if (host) {
            g_presenting = YES;
            [host presentViewController:menu animated:YES completion:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                g_presenting = NO;
            });
        } else if (original) {
            original(target, cmd);
        }
    } @catch (__unused NSException *exception) {
        g_presenting = NO;
        if (original) original(target, cmd);
    }
}

#pragma mark - Hook

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

    C18ShowPowerMenu(self, cmd, original);
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

static void C18InstallHooks(void) {
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

__attribute__((constructor)) static void C18PowerMenuInit(void) {
    @autoreleasepool {
        C18InstallHooks();
        if (g_count == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_count == 0) C18InstallHooks();
            });
        }
    }
}
