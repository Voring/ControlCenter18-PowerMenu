// C18PowerMenu - Power menu for ControlCenter18 (iOS 16 / 17, roothide)
// ControlCenter18's power button only reacts to a long press; the hook below is
// that long-press entry point and shows our own menu (no third-party controller).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <fcntl.h>

extern char **environ;

typedef void (*PresentIMP)(id, SEL);

typedef NS_ENUM(NSInteger, C18PowerAction) {
    C18PowerActionRespring = 0,
    C18PowerActionReboot,
    C18PowerActionShutdown,
    C18PowerActionSafeMode,
    C18PowerActionLdRestart,
    C18PowerActionUserspaceReboot,
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
        case C18PowerActionRespring:   C18Spawn(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]); break;
        case C18PowerActionReboot:     C18Spawn(@"/usr/bin/reboot", @[]); break;
        case C18PowerActionShutdown:   if (original) original(target, cmd); break;
        case C18PowerActionSafeMode:   C18Spawn(@"/usr/bin/killall", @[@"-SEGV", @"SpringBoard"]); break;
        case C18PowerActionLdRestart:  C18Spawn(@"/usr/bin/ldrestart", @[]); break;
        case C18PowerActionUserspaceReboot: C18Spawn(@"/usr/bin/launchctl", @[@"reboot", @"userspace"]); break;
    }
}

#pragma mark - Menu model

static NSArray<NSDictionary *> *C18MenuItems(void) {
    return @[
        @{@"title": @"注销",         @"glyph": @"power",                          @"action": @(C18PowerActionRespring)},
        @{@"title": @"重启",         @"glyph": @"arrow.clockwise",                @"action": @(C18PowerActionReboot)},
        @{@"title": @"关机",         @"glyph": @"power",                          @"action": @(C18PowerActionShutdown)},
        @{@"title": @"安全模式",     @"glyph": @"exclamationmark.triangle",        @"action": @(C18PowerActionSafeMode)},
        @{@"title": @"软重启设备",   @"glyph": @"arrow.triangle.2.circlepath",    @"action": @(C18PowerActionLdRestart)},
        @{@"title": @"重启用户空间", @"glyph": @"arrow.uturn.left.circle",        @"action": @(C18PowerActionUserspaceReboot)},
    ];
}

static UIImage *C18Glyph(NSString *name, CGFloat point) {
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:point weight:UIImageSymbolWeightMedium];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"circle" withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Menu view controller (self drawn)

@interface C18MenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic, copy) void (^handler)(C18PowerAction);
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UITableView *table;
@end

@implementation C18MenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.items = C18MenuItems();

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.blur.frame = self.view.bounds;
    self.blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.blur];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:dim];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    [dim addGestureRecognizer:tap];

    CGFloat cardWidth = MIN(CGRectGetWidth(self.view.bounds) - 44, 372);
    CGFloat rowHeight = 56;
    CGFloat headerHeight = 96;
    CGFloat cardHeight = headerHeight + rowHeight * self.items.count;

    self.card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardWidth, cardHeight)];
    self.card.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    self.card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.card.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.72];
    self.card.layer.cornerRadius = 36;
    self.card.layer.cornerCurve = kCACornerCurveContinuous;
    self.card.layer.masksToBounds = YES;
    [self.view addSubview:self.card];

    UIImageView *glyph = [[UIImageView alloc] initWithImage:C18Glyph(@"circle.dotted", 24)];
    glyph.tintColor = [UIColor whiteColor];
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    glyph.frame = CGRectMake(0, 22, cardWidth, 24);
    glyph.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.card addSubview:glyph];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 54, cardWidth, 26)];
    title.text = @"电源";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.card addSubview:title];

    UIView *hairline = [[UIView alloc] initWithFrame:CGRectMake(0, headerHeight - 0.5, cardWidth, 0.5)];
    hairline.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    hairline.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.card addSubview:hairline];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, headerHeight, cardWidth, rowHeight * self.items.count)
                                                  style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.table.separatorInset = UIEdgeInsetsZero;
    self.table.scrollEnabled = NO;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = rowHeight;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.card addSubview:self.table];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.blur.frame = self.view.bounds;
    CGFloat cardWidth = MIN(CGRectGetWidth(self.view.bounds) - 44, 372);
    CGFloat rowHeight = 56;
    CGFloat headerHeight = 96;
    CGRect f = self.card.frame;
    f.size = CGSizeMake(cardWidth, headerHeight + rowHeight * self.items.count);
    f.origin = CGPointMake((CGRectGetWidth(self.view.bounds) - f.size.width) / 2,
                           (CGRectGetHeight(self.view.bounds) - f.size.height) / 2);
    self.card.frame = f;
    self.table.frame = CGRectMake(0, headerHeight, f.size.width, rowHeight * self.items.count);
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"c18row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        cell.selectedBackgroundView = sel;
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        cell.imageView.tintColor = [UIColor whiteColor];
    }
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.imageView.image = C18Glyph(item[@"glyph"], 22);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    C18PowerAction action = (C18PowerAction)[self.items[indexPath.row][@"action"] integerValue];
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
