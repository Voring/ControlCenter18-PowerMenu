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
    C18PowerActionRestartDesktop,     // 重启桌面（保留枚举，菜单已移除）
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

// roothide hides the bootstrap root, so /var/jb does not exist there. Every
// spawn attempt below needs the *real* path, otherwise it silently fails with
// "not executable" - that is exactly why userspace reboot and safe mode did
// nothing. Resolve the root at runtime and log each step.
static NSString *C18DylibPrefix(void) {
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)&C18DylibPrefix, &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            NSRange r = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
            if (r.location != NSNotFound) prefix = [path substringToIndex:r.location];
        }
    });
    return prefix;
}

// roothide ships libroothide.dylib with "const char *jbroot(const char *)".
// CCRespring (which the user confirmed works) links it directly; we load it at
// runtime and use the very same translation instead of guessing /var/jb.
static void *C18RoohideHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *prefix = C18DylibPrefix();
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        if (prefix) [paths addObject:[prefix stringByAppendingPathComponent:@"usr/lib/libroothide.dylib"]];
        [paths addObject:@"/usr/lib/libroothide.dylib"];
        [paths addObject:@"/var/jb/usr/lib/libroothide.dylib"];
        for (NSString *path in paths) {
            handle = dlopen(path.UTF8String, RTLD_LAZY);
            if (handle) { C18Log(@"libroothide loaded from %@", path); break; }
            C18Log(@"libroothide dlopen failed %@", path);
        }
        if (!handle) {
            handle = dlopen("libroothide.dylib", RTLD_LAZY);
            if (handle) C18Log(@"libroothide loaded by name");
        }
        if (handle) {
            if (!dlsym(handle, "jbroot")) C18Log(@"libroothide has no jbroot symbol");
        }
    });
    return handle;
}

static const char *(*C18JBrootFn(void))(const char *) {
    void *handle = C18RoohideHandle();
    if (!handle) return NULL;
    static const char *(*fn)(const char *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (const char *(*)(const char *))dlsym(handle, "jbroot");
    });
    return fn;
}

// Real path for a jbroot-relative path, e.g. "/usr/bin/launchctl".
static NSString *C18JBPath(NSString *relative) {
    const char *(*fn)(const char *) = C18JBrootFn();
    if (fn) {
        const char *p = fn(relative.UTF8String);
        if (p && p[0]) return [NSString stringWithUTF8String:p];
    }
    return nil;
}

static BOOL C18IsExec(NSString *path) {
    return path.length > 1 && [[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

static NSString *C18ScanContainersForRoot(void) {
    NSString *base = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
    C18Log(@"scan %@ -> %lu entries", base, (unsigned long)dirs.count);
    for (NSString *d in dirs) {
        NSString *cand = [[base stringByAppendingPathComponent:d] stringByAppendingPathComponent:@".jbroot"];
        if (C18IsExec([cand stringByAppendingPathComponent:@"usr/bin/killall"])) return cand;
    }
    return nil;
}

static NSString *C18JBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1) roothide runtime translation - authoritative
        NSString *probe = C18JBPath(@"/usr/bin/killall");
        if (probe) C18Log(@"jbroot probe %@ (exists=%d)", probe, C18IsExec(probe));
        if (probe.length) {
            NSString *r = [probe stringByDeletingLastPathComponent];   // .../usr/bin
            r = [r stringByDeletingLastPathComponent];                  // .../usr
            r = [r stringByDeletingLastPathComponent];                  // jbroot
            root = r;
            C18Log(@"jbroot from libroothide = %@", root);
        }

        // 2) environment
        if (!root) {
            for (NSString *key in @[@"JBROOT", @"JB_ROOT", @"DOPAMINE_ROOT"]) {
                NSString *v = NSProcessInfo.processInfo.environment[key];
                if (C18IsExec([v stringByAppendingPathComponent:@"usr/bin/killall"])) {
                    root = v;
                    C18Log(@"jbroot from env %@ = %@", key, v);
                    break;
                }
            }
        }

        // 3) the ".jbroot" symlink sitting next to our own dylib
        if (!root && C18DylibPrefix()) {
            NSString *prefix = C18DylibPrefix();
            C18Log(@"dylib prefix = %@", prefix);
            if (C18IsExec([prefix stringByAppendingPathComponent:@"usr/bin/killall"])) {
                root = prefix;
                C18Log(@"jbroot from dylib prefix = %@", root);
            }
        }

        // 4) classic rootless layout
        if (!root && C18IsExec(@"/var/jb/usr/bin/killall")) {
            root = @"/var/jb";
            C18Log(@"jbroot = /var/jb");
        }

        // 5) hidden root inside app containers
        if (!root) {
            root = C18ScanContainersForRoot();
            if (root) C18Log(@"jbroot from container scan = %@", root);
        }

        if (!root) {
            root = @"/var/jb";
            C18Log(@"jbroot UNRESOLVED, falling back to %@", root);
        }
        C18Log(@"jbroot final = %@", root);
    });
    return root;
}

static NSArray<NSString *> *C18Candidates(NSString *relative) {
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    NSString *translated = C18JBPath(relative);
    if (translated.length) [list addObject:translated];
    NSString *full = [C18JBRoot() stringByAppendingPathComponent:relative];
    if (full.length && ![list containsObject:full]) [list addObject:full];
    NSString *plainJB = [@"/var/jb" stringByAppendingPathComponent:relative];
    if (![list containsObject:plainJB]) [list addObject:plainJB];
    if (![list containsObject:relative]) [list addObject:relative];
    return list;
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
    if (rc != 0) C18Log(@"spawn rc=%d (%@)", rc, path);
    return rc == 0 && pid > 0;
}

static BOOL C18Run(NSString *relative, NSArray<NSString *> *args) {
    if (!C18IsExec([C18JBRoot() stringByAppendingPathComponent:relative])) {
        C18Log(@"root %@ has no executable %@", C18JBRoot(), relative);
    }
    for (NSString *path in C18Candidates(relative)) {
        if (!C18IsExec(path)) {
            C18Log(@"skip %@ (not executable)", path);
            continue;
        }
        BOOL ok = C18SpawnPath(path, args);
        C18Log(@"spawn %@ %@ -> %d", path, [args componentsJoinedByString:@" "], ok);
        if (ok) return YES;
    }
    C18Log(@"spawn %@ FAILED (no working candidate)", relative);
    return NO;
}

#pragma mark - actions

static void C18KillSelf(int signal) {
    C18Log(@"kill SpringBoard with signal %d", signal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kill(getpid(), signal);

        if (signal == SIGSEGV) {
            // A blocked / ignored SIGSEGV is why "safe mode" looked like a
            // no-op. Give the handler a moment, then force a real fault.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                C18Log(@"SIGSEGV was swallowed, forcing a fault");
                raise(SIGSEGV);
                *(volatile int *)0 = 0;
                __builtin_trap();
            });
        }
    });
}

// Some SpringBoard builds expose reboot/shutdown helpers; use them before
// falling back to spawning a binary (which the sandbox often blocks).
static BOOL C18DumpServiceOnce = NO;
static void C18DumpServiceSelectors(id inst) {
    if (C18DumpServiceOnce || !inst) return;
    C18DumpServiceOnce = YES;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(inst), &count);
    NSMutableArray<NSString *> *hit = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i]));
        if ([n rangeOfString:@"reboot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"shutdown" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"exitAnd" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"restart" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"safe" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"power" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [hit addObject:n];
        }
    }
    free(methods);
    C18Log(@"FBSystemService methods: %@", hit);
}

static id C18SystemServiceInstance(void) {
    Class cls = NSClassFromString(@"FBSystemService");
    if (!cls) { C18Log(@"FBSystemService class missing"); return nil; }

    id inst = nil;
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if ([cls respondsToSelector:sharedSel]) {
        inst = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
    }
    if (!inst) {
        SEL alt = NSSelectorFromString(@"sharedService");
        if ([cls respondsToSelector:alt]) inst = ((id (*)(id, SEL))objc_msgSend)(cls, alt);
    }
    if (!inst) {
        inst = [cls new];
        C18Log(@"FBSystemService has no shared instance, using fresh object");
    }
    C18DumpServiceSelectors(inst);
    return inst;
}

static BOOL C18CallSystemService(NSArray<NSString *> *selectors) {
    id inst = C18SystemServiceInstance();
    if (!inst) return NO;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![inst respondsToSelector:sel]) continue;
        C18Log(@"FBSystemService %@", name);
        if ([name hasSuffix:@":"]) {
            ((void (*)(id, SEL, id))objc_msgSend)(inst, sel, nil);
        } else {
            ((void (*)(id, SEL))objc_msgSend)(inst, sel);
        }
        return YES;
    }
    C18Log(@"FBSystemService none of %@", selectors);
    return NO;
}

// shutdownAndReboot: takes a BOOL - YES reboots, NO powers off. Passing nil
// (as we did before) reads as NO, which is why "reboot" turned into a shutdown.
static BOOL C18CallSystemServiceBool(NSString *name, BOOL value) {
    id inst = C18SystemServiceInstance();
    if (!inst) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![inst respondsToSelector:sel]) {
        C18Log(@"FBSystemService missing %@", name);
        return NO;
    }
    C18Log(@"FBSystemService %@(%d)", name, value);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, sel, value);
    return YES;
}

static void C18RunAction(C18PowerAction action) {
    C18Log(@"action %ld", (long)action);
    switch (action) {
        case C18PowerActionSoftRespring:
            // Respring: graceful SpringBoard restart.
            C18KillSelf(SIGTERM);
            break;
        case C18PowerActionHardRespring:
            C18KillSelf(SIGKILL);
            break;
        case C18PowerActionRestartDesktop:
            // LDRestart: restart daemons + SpringBoard through ldrestart.
            if (!C18Run(@"/usr/bin/ldrestart", @[])) {
                C18KillSelf(SIGTERM);
            }
            break;
        case C18PowerActionSafeMode: {
            // SafeMode: same command CCRespring uses - killall -SEGV SpringBoard.
            if (!C18Run(@"/usr/bin/killall", @[@"-SEGV", @"SpringBoard"])) {
                C18Log(@"safe mode: killall unavailable, crashing in-process");
                C18KillSelf(SIGSEGV);
            }
            break;
        }
        case C18PowerActionUserspaceReboot: {
            // RebootUserspace: launchctl reboot userspace, exactly like
            // CCRespring. If the sandbox blocks the spawn there is no
            // in-process equivalent, so fall back to LDRestart (keeps the
            // jailbreak, restarts daemons + SpringBoard).
            if (!C18Run(@"/usr/bin/launchctl", @[@"reboot", @"userspace"])) {
                C18Log(@"userspace reboot: launchctl blocked, falling back to ldrestart");
                if (!C18Run(@"/usr/bin/ldrestart", @[])) {
                    C18KillSelf(SIGTERM);
                }
            }
            break;
        }
        case C18PowerActionReboot:
            // Reboot: shutdownAndReboot:YES. Older builds passed nil here and
            // the device simply powered off.
            if (!C18CallSystemServiceBool(@"shutdownAndReboot:", YES)) {
                if (!C18CallSystemService(@[@"reboot", @"restartDevice"])) {
                    C18Run(@"/usr/bin/reboot", @[]);
                }
            }
            break;
        case C18PowerActionShutdown:
            // Shutdown: shutdownAndReboot:NO powers off immediately.
            if (!C18CallSystemServiceBool(@"shutdownAndReboot:", NO)) {
                if (!C18CallSystemService(@[@"shutdown", @"shutdownAndPowerOff", @"exitAndShutdown"])) {
                    C18Log(@"shutdown: no usable selector");
                }
            }
            break;
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

// Backdrop: one full-strength *adaptive* system material and no manual dim.
// The adaptive style follows light/dark mode by itself, so light mode stays
// light and dark mode gets its own darkening from the material - we never add
// a black overlay on top of it.
static const CGFloat kBackdropAlpha = 1.0;
static const CGFloat kDimAlpha = 0.0;   // no dimming at all
static const CGFloat kNudgeX = 11.5;   // half a row left, a quarter row back right
static const CGFloat kNudgeY = 23.0;   // half a row down

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
@property (nonatomic, strong) C18MenuCard *confirmCard;
@property (nonatomic, strong) UIView *confirmShield;
@property (nonatomic, strong) UIView *overlayView;
@property (nonatomic, copy) void (^onDismiss)(void);
- (void)askConfirmForTitle:(NSString *)title action:(C18PowerAction)action;
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
    highlight.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.15];
    highlight.alpha = 0;
    highlight.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:highlight];

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    label.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    UIImageView *icon = [[UIImageView alloc] init];
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
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
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],
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

    // A row inside the confirmation card: cancel only closes that card.
    if (self.confirmCard) {
        if (action == C18PowerActionCancel) {
            [self dismissConfirm];
        } else {
            [self performAction:action];
        }
        return;
    }

    switch (action) {
        case C18PowerActionReboot:
            [self askConfirmForTitle:@"是否确认重启设备？" action:action];
            break;
        case C18PowerActionShutdown:
            [self askConfirmForTitle:@"是否确认关机？" action:action];
            break;
        default:
            [self performAction:action];
            break;
    }
}

- (void)performAction:(C18PowerAction)action {
    void (^dismiss)(void) = self.onDismiss;
    if (dismiss) dismiss();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        C18RunAction(action);
    });
}

- (void)dismissConfirm {
    UIView *shield = self.confirmShield;
    self.confirmShield = nil;
    [UIView animateWithDuration:0.16 animations:^{
        self.confirmCard.alpha = 0;
        self.confirmCard.transform = CGAffineTransformMakeScale(0.94, 0.94);
        shield.alpha = 0;
    } completion:^(BOOL finished) {
        [self.confirmCard removeFromSuperview];
        [shield removeFromSuperview];
        self.confirmCard = nil;
    }];
}

// Second factor for the two irreversible rows. Same material, same row
// anatomy; it sits at the menu's own x so the two line up vertically, and a
// transparent shield keeps the menu underneath untouchable while it is up.
- (void)askConfirmForTitle:(NSString *)title action:(C18PowerAction)action {
    if (self.confirmCard || !self.overlayView) return;

    CGFloat width = self.card.bounds.size.width;
    CGFloat height = kRowHeight * 3;
    CGRect screen = self.overlayView.bounds;
    // Same x as the menu so the two cards line up on the right edge; vertically
    // centred, so it reads as a modal question rather than a third menu row.
    C18MenuCard *confirm = [[C18MenuCard alloc] initWithFrame:
        CGRectMake(self.card.frame.origin.x, (screen.size.height - height) / 2, width, height)];

    UIView *titleRow = [[UIView alloc] initWithFrame:CGRectZero];
    titleRow.backgroundColor = [UIColor clearColor];
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [titleRow addSubview:titleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor constant:12],
        [titleLabel.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor constant:-12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
    ]];
    [confirm.rows addObject:titleRow];
    [confirm.blur.contentView addSubview:titleRow];

    C18MenuCard *saved = self.card;
    self.card = confirm;
    [self addRowWithTitle:@"确认" glyph:@"checkmark" destructive:YES
                    action:action last:NO];
    [self addRowWithTitle:@"取消" glyph:@"xmark" destructive:NO
                    action:C18PowerActionCancel last:YES];
    self.card = saved;
    [confirm layoutRows];

    // Full-screen shield: while the confirmation is up, the menu rows and the
    // floating power circle underneath must not react to touches at all.
    UIView *shield = [[UIView alloc] initWithFrame:self.overlayView.bounds];
    shield.backgroundColor = [UIColor clearColor];
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *shieldTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(backgroundTapped)];
    [shield addGestureRecognizer:shieldTap];
    shield.alpha = 0;
    [self.overlayView addSubview:shield];
    self.confirmShield = shield;

    confirm.alpha = 0;
    confirm.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [self.overlayView addSubview:confirm];
    [self.overlayView bringSubviewToFront:confirm];
    self.confirmCard = confirm;

    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        shield.alpha = 1;
        confirm.alpha = 1;
        confirm.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)backgroundTapped {
    if (self.confirmCard) {
        [self dismissConfirm];
        return;
    }
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

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    backdrop.frame = screen;
    backdrop.alpha = kBackdropAlpha;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:backdrop];

    UIView *dim = [[UIView alloc] initWithFrame:screen];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:kDimAlpha];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(backgroundTapped)];
    [dim addGestureRecognizer:tap];
    [overlay addSubview:dim];
    vc.overlayView = overlay;

    NSArray<NSDictionary *> *items = @[
        @{@"t": @"快速注销", @"g": @"rays",                          @"a": @(C18PowerActionSoftRespring)},
        @{@"t": @"重启空间", @"g": @"arrow.clockwise.circle",        @"a": @(C18PowerActionUserspaceReboot)},
        @{@"t": @"安全模式", @"g": @"shield.lefthalf.filled",        @"a": @(C18PowerActionSafeMode)},
        @{@"t": @"重启设备", @"g": @"exclamationmark.arrow.circlepath", @"a": @(C18PowerActionReboot)},
        @{@"t": @"设备关机", @"g": @"power",                          @"a": @(C18PowerActionShutdown)},
    ];

    CGFloat cardWidth = 200;
    CGFloat cardHeight = kRowHeight * (items.count + 1);
    CGFloat right = screen.size.width - 12;
    CGFloat x = MIN(MAX(glyph.origin.x + glyph.size.width - cardWidth, 12), right - cardWidth);
    CGFloat y = glyph.origin.y + glyph.size.height + 8;

    // Nudge: up half a row, left half a row, so the card reads as opening under
    // the power button itself.
    x -= kNudgeX;
    y -= 23;
    if (x < 12) x = 12;
    if (y + cardHeight > screen.size.height - 40) {
        y = MAX(glyph.origin.y - cardHeight - 8, 40);
    }
    if (y < 40) y = 40;

    C18MenuCard *card = [[C18MenuCard alloc] initWithFrame:CGRectMake(x, y, cardWidth, cardHeight)];
    vc.card = card;
    [overlay addSubview:card];

    // The real glyph sits behind the blur; redraw it as a floating circle at its
    // own spot - nudged half a row left and one row up so it clears the card -
    // using the same material as the card so the two read as one layer.
    CGFloat side = MAX(34, MIN(glyph.size.width, 42));
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMidX(glyph) - side / 2 - kNudgeX,
                                                             CGRectGetMidY(glyph) - side / 2 - kNudgeY,
                                                             side, side)];
    circle.backgroundColor = [UIColor clearColor];
    circle.layer.cornerRadius = side / 2;
    circle.layer.cornerCurve = kCACornerCurveContinuous;
    circle.clipsToBounds = YES;

    UIVisualEffectView *circleBlur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    circleBlur.frame = circle.bounds;
    circleBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [circle addSubview:circleBlur];

    UIImageView *powerIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"power"
              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]]];
    powerIcon.tintColor = [UIColor labelColor];
    powerIcon.contentMode = UIViewContentModeScaleAspectFit;
    powerIcon.frame = CGRectMake((side - 21) / 2, (side - 21) / 2, 21, 21);
    powerIcon.userInteractionEnabled = NO;
    [circle addSubview:powerIcon];

    UITapGestureRecognizer *circleTap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(backgroundTapped)];
    [circle addGestureRecognizer:circleTap];
    [overlay addSubview:circle];

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

    // Pop-in: the card scales up while the backdrop fades in.
    card.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.92, 0.92),
                                                 CGAffineTransformMakeTranslation(0, -18));
    card.alpha = 0;
    circle.alpha = 0;
    backdrop.alpha = 0;
    dim.alpha = 0;

    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];

    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        card.transform = CGAffineTransformIdentity;
        card.alpha = 1;
        circle.alpha = 1;
        backdrop.alpha = kBackdropAlpha;
        dim.alpha = 1;
    } completion:nil];
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
