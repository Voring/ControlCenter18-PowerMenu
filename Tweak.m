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

#pragma mark - Jailbreak root

// Walk up from our own dylib path to the real jbroot, no libroothide needed.
static NSString *C18JBROOT(void) {
    static NSString *root = nil;
    if (root) return root;

    Dl_info info;
    if (dladdr((__bridge void *)self, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        NSRange r = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
        if (r.location != NSNotFound) {
            root = [path substringToIndex:r.location];
        } else {
            r = [path rangeOfString:@"/Library/ControlCenter/Bundles/"];
            if (r.location != NSNotFound) root = [path substringToIndex:r.location];
        }
    }
    if (root.length == 0) root = @"/var/jb";
    return root;
}

static NSString *C18Tool(NSString *name) {
    NSString *jb = C18JBROOT();
    for (NSString *dir in @[@"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin"]) {
        NSString *p = [jb stringByAppendingPathComponent:[dir stringByAppendingPathComponent:name]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    for (NSString *dir in @[@"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin"]) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

static void C18Run(NSArray<NSString *> *argv) {
    if (argv.count == 0) return;
    NSString *tool = C18Tool(argv[0]);
    if (!tool) return;

    NSMutableArray *args = [NSMutableArray arrayWithObject:tool];
    for (NSUInteger i = 1; i < argv.count; i++) [args addObject:argv[i]];

    char **argsC = (char **)calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argsC[i] = strdup(args[i].UTF8String);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, tool.UTF8String, &actions, NULL, argsC, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < args.count; i++) free(argsC[i]);
    free(argsC);
    if (rc != 0 || pid <= 0) return;

    int status = 0;
    for (int i = 0; i < 50; i++) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid || r == -1) break;
        usleep(100 * 1000);
    }
}

#pragma mark - Actions

static void C18DoLogout(void)     { C18Run(@[@"killall", @"-9", @"SpringBoard"]); }
static void C18DoReboot(void)     { C18Run(@[@"reboot"]); }
static void C18DoSafemode(void)   { C18Run(@[@"killall", @"-SEGV", @"SpringBoard"]); }
static void C18DoLdrestart(void)  { C18Run(@[@"ldrestart"]); }
static void C18DoUserspace(void)  { C18Run(@[@"launchctl", @"reboot", @"userspace"]); }

#pragma mark - Menu

static UIViewController *C18TopViewController(void) {
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
    }
    if (!win) win = UIApplication.sharedApplication.keyWindow;

    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static UIWindow *C18HostWindow(void) {
    UIViewController *vc = C18TopViewController();
    if (vc && vc.view.window) return vc.view.window;

    if (!g_fallbackWindow) {
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                g_fallbackWindow = [[UIWindow alloc] initWithWindowScene:ws];
                break;
            }
        }
        if (!g_fallbackWindow) g_fallbackWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        g_fallbackWindow.windowLevel = UIWindowLevelAlert + 1;
        g_fallbackWindow.backgroundColor = UIColor.clearColor;
        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = UIColor.clearColor;
        g_fallbackWindow.rootViewController = root;
        g_fallbackWindow.hidden = NO;
    }
    return g_fallbackWindow;
}

static void C18PresentMenu(void) {
    if (g_presenting) return;

    UIViewController *host = C18TopViewController();
    if (!host) {
        host = C18HostWindow().rootViewController;
    }
    if (!host) return;

    g_presenting = YES;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"电源"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [sheet addAction:[UIAlertAction actionWithTitle:@"注销"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            C18DoLogout();
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"重启"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            C18DoReboot();
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"关机"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (int i = 0; i < g_count; i++) {
                if (g_orig[i]) { g_orig[i](nil, @selector(presentPowerDownTransientOverlay)); break; }
            }
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"安全模式"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            C18DoSafemode();
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"软重启设备"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            C18DoLdrestart();
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"重启用户空间"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            C18DoUserspace();
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) {
        g_presenting = NO;
    }]];

    [host presentViewController:sheet animated:YES completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_presenting && !sheet.presentingViewController) g_presenting = NO;
    });
}

#pragma mark - Hook

static void C18Hook(id self, SEL _cmd) {
    @try {
        C18PresentMenu();
    } @catch (NSException *e) {
        for (int i = 0; i < g_count; i++) {
            if ([self isKindOfClass:g_cls[i]] && g_orig[i]) {
                g_orig[i](self, _cmd);
                return;
            }
        }
    }
}

static void C18InstallHook(void) {
    int numClasses = 0;
    Class *classes = objc_copyClassList(&numClasses);
    if (!classes) return;

    for (int i = 0; i < numClasses && g_count < 16; i++) {
        Class cls = classes[i];
        SEL sel = @selector(presentPowerDownTransientOverlay);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        if (class_getMethodImplementation(cls, sel) == NULL) continue;

        unsigned int count = 0;
        Method *list = class_copyMethodList(cls, &count);
        BOOL owns = NO;
        for (unsigned int j = 0; j < count; j++) {
            if (method_getName(list[j]) == sel) { owns = YES; break; }
        }
        free(list);
        if (!owns) continue;

        IMP orig = method_getImplementation(m);
        method_setImplementation(m, (IMP)C18Hook);
        g_orig[g_count] = (PresentIMP)orig;
        g_cls[g_count] = cls;
        g_count++;
    }
    free(classes);
}

__attribute__((constructor)) static void C18Init(void) {
    @autoreleasepool {
        C18InstallHook();
        if (g_count == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                C18InstallHook();
            });
        }
    }
}
