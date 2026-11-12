// C18PowerMenu - Power menu for ControlCenter18 (iOS 16 / 17, roothide)
// Turns the Control Center power button into a native menu instead of shutting down.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <fcntl.h>

extern char **environ;

typedef void (*PresentIMP)(id, SEL);

static PresentIMP g_orig[16];
static Class g_cls[16];
static int g_count = 0;
static BOOL g_presenting = NO;
static UIWindow *g_fallbackWindow = nil;

#pragma mark - Path helpers

// Resolve the jailbreak root without relying on libroothide: our own image
// lives under <root>/Library/MobileSubstrate/DynamicLibraries/.
static NSString *C18JBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)&C18JBRoot, &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            NSRange r = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
            if (r.location != NSNotFound) {
                root = [path substringToIndex:r.location];
            }
        }
        if (!root && [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/killall"]) {
            root = @"/var/jb";
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
    int rc = posix_spawn(&pid, path.UTF8String, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    if (rc == 0 && pid > 0) {
        waitpid(pid, NULL, WNOHANG);
    }
}

#pragma mark - Actions

typedef NS_ENUM(NSInteger, C18PowerAction) {
    C18PowerActionRespring = 0,
    C18PowerActionReboot,
    C18PowerActionShutdown,
    C18PowerActionSafeMode,
    C18PowerActionLdRestart,
    C18PowerActionUserspaceReboot,
};

static void C18RunAction(C18PowerAction action, PresentIMP original, id target, SEL cmd) {
    switch (action) {
        case C18PowerActionRespring:
            C18Spawn(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]);
            break;
        case C18PowerActionReboot:
            C18Spawn(@"/usr/bin/reboot", @[]);
            break;
        case C18PowerActionShutdown:
            if (original) original(target, cmd);
            break;
        case C18PowerActionSafeMode:
            C18Spawn(@"/usr/bin/killall", @[@"-SEGV", @"SpringBoard"]);
            break;
        case C18PowerActionLdRestart:
            C18Spawn(@"/usr/bin/ldrestart", @[]);
            break;
        case C18PowerActionUserspaceReboot:
            C18Spawn(@"/usr/bin/launchctl", @[@"reboot", @"userspace"]);
            break;
    }
}

#pragma mark - Presentation

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

static UIViewController *C18FallbackViewController(void) {
    if (g_fallbackWindow && g_fallbackWindow.rootViewController) {
        return g_fallbackWindow.rootViewController;
    }
    g_fallbackWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    g_fallbackWindow.windowLevel = UIWindowLevelAlert + 1;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    g_fallbackWindow.rootViewController = root;
    [g_fallbackWindow makeKeyAndVisible];
    return root;
}

static void C18ShowPowerMenu(id target, SEL cmd, PresentIMP original) {
    if (g_presenting) return;

    UIViewController *host = C18TopViewController();
    if (!host) host = C18FallbackViewController();
    if (!host) {
        if (original) original(target, cmd);
        return;
    }

    g_presenting = YES;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"电源"
                                                                  message:@"ControlCenter18"
                                                           preferredStyle:UIAlertControllerStyleAlert];

    __weak id weakTarget = target;

    void (^add)(NSString *, C18PowerAction, UIAlertActionStyle) =
        ^(NSString *title, C18PowerAction action, UIAlertActionStyle style) {
            [sheet addAction:[UIAlertAction actionWithTitle:title style:style handler:^(UIAlertAction *a) {
                g_presenting = NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    C18RunAction(action, original, weakTarget, cmd);
                });
            }]];
        };

    add(@"注销", C18PowerActionRespring, UIAlertActionStyleDefault);
    add(@"重启", C18PowerActionReboot, UIAlertActionStyleDestructive);
    add(@"关机", C18PowerActionShutdown, UIAlertActionStyleDestructive);
    add(@"安全模式", C18PowerActionSafeMode, UIAlertActionStyleDestructive);
    add(@"软重启设备", C18PowerActionLdRestart, UIAlertActionStyleDefault);
    add(@"重启用户空间", C18PowerActionUserspaceReboot, UIAlertActionStyleDefault);

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        g_presenting = NO;
    }]];

    [host presentViewController:sheet animated:YES completion:nil];
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

    @try {
        C18ShowPowerMenu(self, cmd, original);
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

        // ControlCenter18 / SpringBoard bundles may register later; retry once.
        if (g_count == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_count == 0) C18InstallHooks();
            });
        }
    }
}
