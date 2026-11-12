// C18PowerMenu - power menu for ControlCenter18 (iOS 16 / 17, roothide)
//
// The long press on CC18's power glyph (top-right of Control Center) still ends
// up in presentPowerDownTransientOverlay, which we hook. We show a card that
// copies the system menu look - same blurred material, title on the left, SF
// symbol on the right - pinned right under that glyph. The card lives inside
// the existing key window (a brand-new UIWindow in SpringBoard does not reliably
// receive touches).

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
    C18PowerActionCancel,             // 取消
};

static PresentIMP g_orig[16];
static Class g_cls[16];
static int g_count = 0;

#pragma mark - logging

static void C18Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *path = @"/var/mobile/Library/C18PowerMenu.log";
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    if (old.length > 4000) old = [old substringFromIndex:old.length - 2000];
    NSString *content = [old stringByAppendingFormat:@"%@ %@\n", [NSDate date], line];
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

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

static NSArray<NSString *> *C18Candidates(NSString *relative) {
    NSString *full = [C18JBRoot() stringByAppendingPathComponent:relative];
    if ([full isEqualToString:relative]) return @[relative];
    return @[full, relative];
}

static BOOL C18SpawnPath(NSString *path, NSArray<NSString *> *args) {
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
    int rc = posix_spawn(&pid, path.UTF8String, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    return rc == 0 && pid > 0;
}

static void C18Run(NSString *relative, NSArray<NSString *> *args) {
    for (NSString *path in C18Candidates(relative)) {
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            C18Log(@"skip %@ (not executable)", path);
            continue;
        }
        BOOL ok = C18SpawnPath(path, args);
        C18Log(@"spawn %@ %@ -> %d", path, [args componentsJoinedByString:@" "], ok);
        if (ok) return;
    }
    C18Log(@"spawn %@ FAILED (no executable candidate)", relative);
}

#pragma mark - actions

static void C18RunAction(C18PowerAction action) {
    C18Log(@"action %ld", (long)action);
    switch (action) {
        case C18PowerActionSoftRespring:
            C18Run(@"/usr/bin/sbreload", @[]);
            break;
        case C18PowerActionHardRespring:
            C18Run(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]);
            break;
        case C18PowerActionRestartDesktop:
            C18Run(@"/usr/bin/killall", @[@"SpringBoard"]);
            break;
        case C18PowerActionSafeMode:
            C18Run(@"/usr/bin/killall", @[@"-SEGV", @"SpringBoard"]);
            break;
        case C18PowerActionUserspaceReboot:
            C18Run(@"/bin/launchctl", @[@"reboot", @"userspace"]);
            break;
        case C18PowerActionReboot:
            C18Run(@"/usr/bin/reboot", @[]);
            break;
        case C18PowerActionShutdown: {
            Class mgr = NSClassFromString(@"SBLockScreenManager");
            SEL sharedSel = NSSelectorFromString(@"sharedInstanceIfExists");
            id inst = nil;
            if ([mgr respondsToSelector:sharedSel]) {
                inst = ((id (*)(id, SEL))objc_msgSend)(mgr, sharedSel);
            }
            SEL sel = NSSelectorFromString(@"presentPowerDownTransientOverlay");
            if (inst && [inst respondsToSelector:sel]) {
                C18Log(@"shutdown via SBLockScreenManager");
                ((void (*)(id, SEL))objc_msgSend)(inst, sel);
            } else {
                C18Log(@"shutdown fallback (instance=%d)", inst != nil);
                C18Run(@"/usr/bin/halt", @[]);
            }
            break;
        }
        case C18PowerActionCancel:
            break;
    }
}

#pragma mark - power glyph lookup

static UIView *C18FindPowerView(UIView *view) {
    NSString *cls = NSStringFromClass([view class]).lowercaseString;
    BOOL nameHit = [cls containsString:@"c18power"] || [cls containsString:@"powerglyph"] || [cls containsString:@"power"];

    if (nameHit && view.window) {
        CGSize s = view.bounds.size;
        if (s.width >= 14 && s.width <= 110 && s.height >= 14 && s.height <= 110) return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *hit = C18FindPowerView(sub);
        if (hit) return hit;
    }
    return nil;
}

static UIView *C18OverlayView(void) {
    Class cc = NSClassFromString(@"CCUIModularControlCenterOverlayViewController");
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        id vc = w.rootViewController;
        if (![vc isKindOfClass:cc]) continue;
        if (((UIViewController *)vc).view.window) return ((UIViewController *)vc).view;
    }
    return nil;
}

static CGRect C18GlyphRect(void) {
    UIView *overlay = C18OverlayView();
    UIView *power = overlay ? C18FindPowerView(overlay) : nil;
    if (power) return [power convertRect:power.bounds toView:nil];

    CGRect screen = [UIScreen mainScreen].bounds;
    return CGRectMake(screen.size.width - 56, 40, 40, 40);
}

#pragma mark - menu card

static const CGFloat kRowHeight = 46.0;

@interface C18MenuCard : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) NSMutableArray<UIView *> *rows;
- (void)layoutRows;
@end

@implementation C18MenuCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 14;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;

        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
        _blur = [[UIVisualEffectView alloc] initWithEffect:effect];
        _blur.frame = self.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blur];

        _rows = [NSMutableArray array];
    }
    return self;
}

- (void)layoutRows {
    CGFloat y = 0;
    NSUInteger total = self.rows.count;
    NSUInteger index = 0;
    for (UIView *row in self.rows) {
        row.frame = CGRectMake(0, y, self.bounds.size.width, kRowHeight);
        y += kRowHeight;
        BOOL last = (++index == total);
        for (UIView *sub in row.subviews) {
            if (sub.tag == 99) {
                sub.frame = CGRectMake(last ? 0 : 16, kRowHeight - 0.5,
                                       last ? 0 : self.bounds.size.width - 16, 0.5);
                sub.hidden = last;
            }
        }
    }
}

@end

@interface C18MenuViewController : UIViewController
@property (nonatomic, strong) C18MenuCard *card;
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation C18MenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)addRowWithTitle:(NSString *)title
                 glyph:(NSString *)glyph
           destructive:(BOOL)destructive
                action:(C18PowerAction)action
                  last:(BOOL)last {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.backgroundColor = [UIColor clearColor];

    UIView *highlight = [[UIView alloc] init];
    highlight.tag = 777;
    highlight.userInteractionEnabled = NO;
    highlight.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    highlight.alpha = 0;
    highlight.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:highlight];

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    label.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    UIImageView *icon = [[UIImageView alloc] init];
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    icon.image = [UIImage systemImageNamed:glyph withConfiguration:cfg];
    icon.tintColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    [NSLayoutConstraint activateConstraints:@[
        [highlight.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [highlight.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [highlight.topAnchor constraintEqualToAnchor:row.topAnchor],
        [highlight.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],
    ]];

    if (!last) {
        UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
        separator.tag = 99;
        separator.backgroundColor = [UIColor separatorColor];
        [row addSubview:separator];
    }

    UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
    hit.backgroundColor = [UIColor clearColor];
    hit.tag = action;
    [hit addTarget:self action:@selector(rowTouchDown:) forControlEvents:UIControlEventTouchDown];
    [hit addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [hit addTarget:self action:@selector(rowTouchCancel:) forControlEvents:UIControlEventTouchUpOutside];
    [hit addTarget:self action:@selector(rowTouchCancel:) forControlEvents:UIControlEventTouchCancel];
    hit.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:hit];
    [NSLayoutConstraint activateConstraints:@[
        [hit.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [hit.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [hit.topAnchor constraintEqualToAnchor:row.topAnchor],
        [hit.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    [self.card.rows addObject:row];
    [self.card.blur.contentView addSubview:row];
}

- (void)rowTouchDown:(UIButton *)sender {
    UIView *hl = [sender.superview viewWithTag:777];
    [UIView animateWithDuration:0.1 animations:^{ hl.alpha = 1; }];
}

- (void)rowTouchCancel:(UIButton *)sender {
    UIView *hl = [sender.superview viewWithTag:777];
    [UIView animateWithDuration:0.1 animations:^{ hl.alpha = 0; }];
}

- (void)rowTapped:(UIButton *)sender {
    UIView *hl = [sender.superview viewWithTag:777];
    [UIView animateWithDuration:0.1 animations:^{ hl.alpha = 0; }];

    C18PowerAction action = (C18PowerAction)sender.tag;
    void (^dismiss)(void) = self.onDismiss;
    if (dismiss) dismiss();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        C18RunAction(action);
    });
}

- (void)backgroundTapped {
    void (^dismiss)(void) = self.onDismiss;
    if (dismiss) dismiss();
}

@end

#pragma mark - presentation

static UIView *g_overlay = nil;
static C18MenuViewController *g_menuVC = nil;

static void C18HideMenu(void) {
    C18Log(@"hide menu");
    [g_overlay removeFromSuperview];
    g_overlay = nil;
    g_menuVC = nil;
}

static UIWindow *C18HostWindow(void) {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (key) return key;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowScene) return w;
    }
    return nil;
}

static BOOL C18ShowMenu(void) {
    UIWindow *host = C18HostWindow();
    if (!host) {
        C18Log(@"show menu: no host window");
        return NO;
    }

    if (g_overlay) C18HideMenu();

    CGRect glyph = C18GlyphRect();
    CGRect screen = host.bounds;
    C18Log(@"glyph=%.1f,%.1f,%.1f,%.1f screen=%.1fx%.1f",
           glyph.origin.x, glyph.origin.y, glyph.size.width, glyph.size.height,
           screen.size.width, screen.size.height);

    C18MenuViewController *vc = [[C18MenuViewController alloc] init];

    UIView *overlay = [[UIView alloc] initWithFrame:screen];
    overlay.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    backdrop.frame = screen;
    backdrop.alpha = 0.75;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:backdrop];

    UIView *dim = [[UIView alloc] initWithFrame:screen];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(backgroundTapped)];
    [dim addGestureRecognizer:tap];
    [overlay addSubview:dim];

    NSArray<NSDictionary *> *items = @[
        @{@"t": @"快速注销", @"g": @"rays",                          @"a": @(C18PowerActionSoftRespring)},
        @{@"t": @"强制注销", @"g": @"slowmo",                        @"a": @(C18PowerActionHardRespring)},
        @{@"t": @"重启桌面", @"g": @"apps.iphone",                   @"a": @(C18PowerActionRestartDesktop)},
        @{@"t": @"安全模式", @"g": @"shield.lefthalf.filled",        @"a": @(C18PowerActionSafeMode)},
        @{@"t": @"重启空间", @"g": @"arrow.clockwise.circle",        @"a": @(C18PowerActionUserspaceReboot)},
        @{@"t": @"重启设备", @"g": @"exclamationmark.arrow.circlepath", @"a": @(C18PowerActionReboot)},
        @{@"t": @"设备关机", @"g": @"power",                          @"a": @(C18PowerActionShutdown)},
    ];

    CGFloat cardWidth = 200;
    CGFloat cardHeight = kRowHeight * (items.count + 1);
    CGFloat right = screen.size.width - 12;
    CGFloat x = MIN(MAX(glyph.origin.x + glyph.size.width - cardWidth, 12), right - cardWidth);
    CGFloat y = glyph.origin.y + glyph.size.height + 8;

    // Nudge: up one row, left half a row, so the card reads as opening under
    // the power button itself.
    x -= 23;
    y -= 46;
    if (x < 12) x = 12;
    if (y + cardHeight > screen.size.height - 40) {
        y = MAX(glyph.origin.y - cardHeight - 8, 40);
    }
    if (y < 40) y = 40;

    C18MenuCard *card = [[C18MenuCard alloc] initWithFrame:CGRectMake(x, y, cardWidth, cardHeight)];
    vc.card = card;
    [overlay addSubview:card];

    for (NSDictionary *item in items) {
        [vc addRowWithTitle:item[@"t"] glyph:item[@"g"] destructive:NO
                      action:(C18PowerAction)[item[@"a"] integerValue] last:NO];
    }
    [vc addRowWithTitle:@"取消操作" glyph:@"trash" destructive:YES
                  action:C18PowerActionCancel last:YES];
    [card layoutRows];

    __weak typeof(vc) weakVC = vc;
    vc.onDismiss = ^{
        (void)weakVC;
        C18HideMenu();
    };

    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];
    g_overlay = overlay;
    g_menuVC = vc;
    C18Log(@"show menu at %.1f,%.1f size %.1fx%.1f", x, y, cardWidth, cardHeight);
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

    BOOL shown = NO;
    @try {
        shown = C18ShowMenu();
    } @catch (NSException *exception) {
        shown = NO;
        C18Log(@"exception %@", exception);
    }

    if (!shown && original) {
        C18Log(@"fallback to stock");
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
        C18Log(@"hooked %@", NSStringFromClass(cls));
    }

    free(classes);
}

__attribute__((constructor)) static void C18PowerMenuInit(void) {
    @autoreleasepool {
        C18Log(@"init");
        C18InstallPowerHook();

        if (g_count == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_count == 0) C18InstallPowerHook();
            });
        }
    }
}
