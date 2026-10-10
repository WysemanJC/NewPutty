/*
 * main.m: application startup, the menu bar and the other
 * application-wide parts of the native macOS front end.
 *
 * Unlike GTK PuTTY, which runs one session per process, the Mac
 * application is a single process with any number of session
 * windows, in the usual Mac style.
 */

#import <Cocoa/Cocoa.h>

#include <locale.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "putty.h"
#include "ssh.h"
#include "storage.h"
#include "macputty.h"

/* ----------------------------------------------------------------------
 * Per-application constants and small platform functions.
 */

const bool buildinfo_gtk_relevant = true;
const bool share_can_be_downstream = true;
const bool share_can_be_upstream = true;

const unsigned cmdline_tooltype =
    TOOLTYPE_HOST_ARG |
    TOOLTYPE_PORT_ARG |
    TOOLTYPE_NO_VERBOSE_OPTION;

char *x_get_default(const char *key)
{
    return NULL;                       /* no X resources here */
}

char *platform_get_x_display(void)
{
    /* XQuartz, if it's installed, sets DISPLAY for us. */
    const char *display = getenv("DISPLAY");
    return display ? dupstr(display) : NULL;
}

void old_keyfile_warning(void)
{
    /* Not used on this platform. */
}

void cleanup_exit(int code)
{
    sk_cleanup();
    random_save_seed();
    exit(code);
}

static void run_alert(const char *title, const char *msg, bool critical)
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = critical ? NSAlertStyleCritical :
            NSAlertStyleWarning;
        alert.messageText = [NSString stringWithUTF8String:title];
        NSString *info = msg ? [NSString stringWithUTF8String:msg] : nil;
        alert.informativeText = info ? info : @"";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

void modalfatalbox(const char *p, ...)
{
    va_list ap;
    va_start(ap, p);
    char *msg = dupvprintf(p, ap);
    va_end(ap);
    fprintf(stderr, "%s: %s\n", appname, msg);
    char *title = dupprintf("%s Fatal Error", appname);
    run_alert(title, msg, true);
    sfree(title);
    sfree(msg);
    cleanup_exit(1);
}

void nonfatal(const char *p, ...)
{
    va_list ap;
    va_start(ap, p);
    char *msg = dupvprintf(p, ap);
    va_end(ap);
    char *title = dupprintf("%s Error", appname);
    run_alert(title, msg, false);
    sfree(title);
    sfree(msg);
}

void cmdline_error(const char *p, ...)
{
    va_list ap;
    va_start(ap, p);
    char *msg = dupvprintf(p, ap);
    va_end(ap);
    fprintf(stderr, "%s: %s\n", appname, msg);
    /* Started from the Finder, nobody will see stderr. */
    if (!isatty(2)) {
        char *title = dupprintf("%s Command Line Error", appname);
        run_alert(title, msg, true);
        sfree(title);
    }
    sfree(msg);
    exit(1);
}

/* ----------------------------------------------------------------------
 * Starting sessions.
 */

static void after_initial_config(void *vctx, int result)
{
    Conf *conf = (Conf *)vctx;
    if (result > 0)
        macos_open_session(conf);
    else
        conf_free(conf);
}

static void config_box_for(Conf *conf)
{
    char *title = dupcat(appname, " Configuration");
    macos_config_box(title, conf, false, 0, NULL,
                     after_initial_config, conf);
    sfree(title);
}

void macos_new_session_dialog(void)
{
    Conf *conf = conf_new();
    do_defaults(NULL, conf);
    config_box_for(conf);
}

void macos_open_session(Conf *conf)
{
    macos_frontend_new(conf);          /* takes ownership, even on error */
}

void macos_launch_saved_session(const char *name)
{
    Conf *conf = conf_new();
    do_defaults(name, conf);
    if (conf_launchable(conf))
        macos_open_session(conf);
    else
        config_box_for(conf);
}

void macos_session_closed(void)
{
    /* Nothing to do: the app stays running without windows, as Mac
     * apps do, and the Dock icon or New Session gets you a new one. */
}

/* ----------------------------------------------------------------------
 * The command line. The options are the same as for GTK PuTTY, minus
 * the ones that only make sense under X.
 */

static void help(FILE *fp)
{
    if (fprintf(fp,
"PuTTY option summary:\n"
"\n"
"  -fn FONT                  Font, as \"Name size\" (e.g. \"Menlo 12\")\n"
"  -geometry COLSxROWS       Size of window, in characters\n"
"  -sl LINES                 Number of lines of scrollback\n"
"  -fg COLOUR, -bg COLOUR    Foreground/background colour (#rrggbb)\n"
"  -bfg COLOUR, -bbg COLOUR  Foreground/background bold colour\n"
"  -cfg COLOUR, -cbg COLOUR  Foreground/background cursor colour\n"
"  -title TITLE              Window title\n"
"  -sb, +sb                  Do(default) or do not display a scrollbar\n"
"  -log PATH, -sessionlog PATH  Log all output to a file\n"
"  -nethack                  Map numeric keypad to hjklyubn direction keys\n"
"  -host-ca                  Configure trusted host certification authorities\n"
"\n"
"plus the usual connection options (see the PuTTY documentation):\n"
"  -load SESSION, -ssh, -telnet, -raw, -serial, -P PORT, -l USER,\n"
"  -i KEYFILE, -L/-R/-D forwardings, -A/-a, -X/-x and so on.\n"
         ) < 0 || fflush(fp) < 0) {
        perror("output error");
        exit(1);
    }
}

static void version(FILE *fp)
{
    char *buildinfo_text = buildinfo("\n");
    if (fprintf(fp, "%s: %s\n%s\n", appname, ver, buildinfo_text) < 0 ||
        fflush(fp) < 0) {
        perror("output error");
        exit(1);
    }
    sfree(buildinfo_text);
}

static bool parse_colour(const char *val, int *r, int *g, int *b)
{
    unsigned rr, gg, bb;
    if (val[0] == '#' && strlen(val) == 7 &&
        sscanf(val + 1, "%2x%2x%2x", &rr, &gg, &bb) == 3) {
        *r = rr; *g = gg; *b = bb;
        return true;
    }
    if (val[0] == '#' && strlen(val) == 4 &&
        sscanf(val + 1, "%1x%1x%1x", &rr, &gg, &bb) == 3) {
        *r = rr * 17; *g = gg * 17; *b = bb * 17;
        return true;
    }
    return false;
}

static bool want_ca_config_box;

static bool do_cmdline(int argc, char **argv, bool do_everything, Conf *conf)
{
    bool err = false;

#define EXPECTS_ARG if (1) {                                            \
        if (!nextarg) {                                                 \
            err = true;                                                 \
            fprintf(stderr, "%s: %s expects an argument\n", appname, p); \
            continue;                                                   \
        } else {                                                        \
            arglistpos++;                                               \
        }                                                               \
    } else ((void)0)
#define SECOND_PASS_ONLY if (1) {               \
        if (!do_everything)                     \
            continue;                           \
    } else ((void)0)

    CmdlineArgList *arglist = cmdline_arg_list_from_argv(argc, argv);
    size_t arglistpos = 0;
    while (arglist->args[arglistpos]) {
        CmdlineArg *arg = arglist->args[arglistpos++];
        CmdlineArg *nextarg = arglist->args[arglistpos];
        const char *p = cmdline_arg_to_str(arg);
        const char *val = cmdline_arg_to_str(nextarg);
        int ret;

        ret = cmdline_process_param(
            arg, nextarg, do_everything ? 1 : -1, conf);

        if (ret == -2) {
            cmdline_error("option \"%s\" requires an argument", p);
        } else if (ret == 2) {
            arglistpos++;
            continue;
        } else if (ret == 1) {
            continue;
        }

        if (!strcmp(p, "-fn") || !strcmp(p, "-font")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            FontSpec *fs = fontspec_new(val);
            conf_set_fontspec(conf, CONF_font, fs);
            fontspec_free(fs);

        } else if (!strcmp(p, "-cs")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            conf_set_str(conf, CONF_line_codepage, val);

        } else if (!strcmp(p, "-geometry")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            int w, h;
            if (sscanf(val, "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
                conf_set_int(conf, CONF_width, w);
                conf_set_int(conf, CONF_height, h);
            } else {
                err = true;
                fprintf(stderr, "%s: unable to parse geometry \"%s\"\n",
                        appname, val);
            }

        } else if (!strcmp(p, "-sl")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            conf_set_int(conf, CONF_savelines, atoi(val));

        } else if (!strcmp(p, "-fg") || !strcmp(p, "-bg") ||
                   !strcmp(p, "-bfg") || !strcmp(p, "-bbg") ||
                   !strcmp(p, "-cfg") || !strcmp(p, "-cbg")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            int r, g, b;
            if (!parse_colour(val, &r, &g, &b)) {
                err = true;
                fprintf(stderr, "%s: unable to parse colour \"%s\"\n",
                        appname, val);
            } else {
                int index = (!strcmp(p, "-fg") ? 0 :
                             !strcmp(p, "-bg") ? 2 :
                             !strcmp(p, "-bfg") ? 1 :
                             !strcmp(p, "-bbg") ? 3 :
                             !strcmp(p, "-cfg") ? 4 : 5);
                conf_set_int_int(conf, CONF_colours, index*3+0, r);
                conf_set_int_int(conf, CONF_colours, index*3+1, g);
                conf_set_int_int(conf, CONF_colours, index*3+2, b);
            }

        } else if (!strcmp(p, "-title")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            conf_set_str(conf, CONF_wintitle, val);

        } else if (!strcmp(p, "-log")) {
            EXPECTS_ARG;
            SECOND_PASS_ONLY;
            Filename *fn = cmdline_arg_to_filename(nextarg);
            conf_set_filename(conf, CONF_logfilename, fn);
            conf_set_int(conf, CONF_logtype, LGTYP_DEBUG);
            filename_free(fn);

        } else if (!strcmp(p, "-nethack")) {
            SECOND_PASS_ONLY;
            conf_set_bool(conf, CONF_nethack_keypad, true);

        } else if (!strcmp(p, "-sb-") || !strcmp(p, "+sb")) {
            SECOND_PASS_ONLY;
            conf_set_bool(conf, CONF_scrollbar, false);

        } else if (!strcmp(p, "-sb")) {
            SECOND_PASS_ONLY;
            conf_set_bool(conf, CONF_scrollbar, true);

        } else if (!strcmp(p, "-help") || !strcmp(p, "--help")) {
            help(stdout);
            exit(0);

        } else if (!strcmp(p, "-version") || !strcmp(p, "--version")) {
            version(stdout);
            exit(0);

        } else if (!strcmp(p, "-pgpfp")) {
            pgp_fingerprints();
            exit(0);

        } else if (!strcmp(p, "-host-ca") || !strcmp(p, "--host-ca") ||
                   !strcmp(p, "-host_ca") || !strcmp(p, "--host_ca")) {
            want_ca_config_box = true;

        } else if (p[0] != '-') {
            /* Non-option arguments not handled by cmdline.c are errors. */
            if (do_everything) {
                err = true;
                fprintf(stderr, "%s: unexpected non-option argument '%s'\n",
                        appname, p);
            }

        } else {
            err = true;
            fprintf(stderr, "%s: unrecognized option '%s'\n", appname, p);
        }
    }

#undef EXPECTS_ARG
#undef SECOND_PASS_ONLY

    return err;
}

/* ----------------------------------------------------------------------
 * The application delegate and the menu bar.
 */

@protocol PTSessionMenus
- (void)fillSpecialsMenu:(NSMenu *)menu;
@end

@interface PTAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSMenu *savedSessionsMenu;
@property (strong) NSMenu *specialsMenu;
@end

static Conf *startup_conf;             /* the session to start, if any */
static bool startup_config_box;        /* ... and whether to ask first */

@implementation PTAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [NSApp activateIgnoringOtherApps:YES];

    if (want_ca_config_box) {
        show_ca_config_box(NULL);
        if (startup_conf) {
            conf_free(startup_conf);
            startup_conf = NULL;
        }
        return;
    }

    Conf *conf = startup_conf;
    startup_conf = NULL;
    if (!conf)
        return;
    if (startup_config_box)
        config_box_for(conf);
    else
        macos_open_session(conf);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app
                    hasVisibleWindows:(BOOL)visible
{
    if (!visible)
        macos_new_session_dialog();
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    if (!macos_any_session_wants_quit_confirmation())
        return NSTerminateNow;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Quit %s?", appname];
    alert.informativeText = @"Sessions are still active. Quitting will "
        "close all of them.";
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Cancel"];
    return ([alert runModal] == NSAlertFirstButtonReturn) ?
        NSTerminateNow : NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    sk_cleanup();
    random_save_seed();
}

- (void)newSession:(id)sender
{
    macos_new_session_dialog();
}

- (void)orderFrontStandardAboutPanel:(id)sender
{
    macos_about_box(NULL);
}

- (void)launchSavedSession:(id)sender
{
    NSString *name = [sender representedObject];
    if (name)
        macos_launch_saved_session(name.UTF8String);
}

- (void)showHostCAConfig:(id)sender
{
    show_ca_config_box(NULL);
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (menu == self.specialsMenu) {
        id del = NSApp.keyWindow.delegate;
        if ([del respondsToSelector:@selector(fillSpecialsMenu:)]) {
            [(id<PTSessionMenus>)del fillSpecialsMenu:menu];
        } else {
            [menu removeAllItems];
            NSMenuItem *it = [menu addItemWithTitle:@"(None)" action:NULL
                                      keyEquivalent:@""];
            it.enabled = NO;
        }
        return;
    }

    /* Otherwise it's a Saved Sessions menu (in the menu bar, or in a
     * session window's context menu). */
    [menu removeAllItems];
    struct sesslist sl;
    get_sesslist(&sl, true);
    /* skip sl.sessions[0] == Default Settings */
    for (int i = 1; i < sl.nsessions; i++) {
        NSString *name = [NSString stringWithUTF8String:sl.sessions[i]];
        if (!name)
            continue;
        NSMenuItem *it = [menu addItemWithTitle:name
                                         action:@selector(launchSavedSession:)
                                  keyEquivalent:@""];
        it.target = self;
        it.representedObject = name;
    }
    if (sl.nsessions <= 1) {
        NSMenuItem *it = [menu addItemWithTitle:@"(No sessions)" action:NULL
                                  keyEquivalent:@""];
        it.enabled = NO;
    }
    get_sesslist(&sl, false);
}

@end

static NSMenuItem *add_item(NSMenu *menu, NSString *title, SEL action,
                            NSString *key, NSEventModifierFlags mods)
{
    NSMenuItem *it = [menu addItemWithTitle:title action:action
                              keyEquivalent:key ? key : @""];
    if (key)
        it.keyEquivalentModifierMask = mods;
    return it;
}

static NSMenu *add_submenu(NSMenu *bar, NSString *title)
{
    NSMenuItem *it = [bar addItemWithTitle:title action:NULL
                             keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    it.submenu = m;
    return m;
}

static void build_menus(PTAppDelegate *del)
{
    const NSEventModifierFlags CMD = NSEventModifierFlagCommand;
    NSString *app = [NSString stringWithUTF8String:appname];
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
    NSMenu *m;
    NSMenuItem *it;

    /* Application menu */
    m = add_submenu(bar, app);
    it = add_item(m, [@"About " stringByAppendingString:app],
                  @selector(orderFrontStandardAboutPanel:), nil, 0);
    it.target = del;
    [m addItem:[NSMenuItem separatorItem]];
    it = add_item(m, @"Trusted Host Certification Authorities...",
                  @selector(showHostCAConfig:), nil, 0);
    it.target = del;
    [m addItem:[NSMenuItem separatorItem]];
    NSMenu *services = [[NSMenu alloc] initWithTitle:@"Services"];
    it = add_item(m, @"Services", NULL, nil, 0);
    it.submenu = services;
    NSApp.servicesMenu = services;
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, [@"Hide " stringByAppendingString:app],
             @selector(hide:), @"h", CMD);
    add_item(m, @"Hide Others", @selector(hideOtherApplications:),
             @"h", CMD | NSEventModifierFlagOption);
    add_item(m, @"Show All", @selector(unhideAllApplications:), nil, 0);
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, [@"Quit " stringByAppendingString:app],
             @selector(terminate:), @"q", CMD);

    /* Session menu */
    m = add_submenu(bar, @"Session");
    it = add_item(m, @"New Session...", @selector(newSession:), @"n", CMD);
    it.target = del;
    it = add_item(m, @"Saved Sessions", NULL, nil, 0);
    del.savedSessionsMenu = [[NSMenu alloc] initWithTitle:@"Saved Sessions"];
    del.savedSessionsMenu.delegate = del;
    it.submenu = del.savedSessionsMenu;
    add_item(m, @"Duplicate Session", @selector(duplicateSession:),
             @"d", CMD | NSEventModifierFlagShift);
    add_item(m, @"Restart Session", @selector(restartSession:),
             @"r", CMD | NSEventModifierFlagShift);
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, @"Change Settings...", @selector(changeSettings:),
             @",", CMD);
    add_item(m, @"Event Log", @selector(showEventLog:),
             @"l", CMD | NSEventModifierFlagShift);
    it = add_item(m, @"Special Commands", NULL, nil, 0);
    del.specialsMenu = [[NSMenu alloc] initWithTitle:@"Special Commands"];
    del.specialsMenu.delegate = del;
    it.submenu = del.specialsMenu;
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, @"Close Window", @selector(performClose:), @"w", CMD);

    /* Edit menu */
    m = add_submenu(bar, @"Edit");
    add_item(m, @"Copy", @selector(copy:), @"c", CMD);
    add_item(m, @"Paste", @selector(paste:), @"v", CMD);
    add_item(m, @"Copy All to Clipboard", @selector(copyAll:), nil, 0);
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, @"Clear Scrollback", @selector(clearScrollback:),
             @"k", CMD);
    add_item(m, @"Reset Terminal", @selector(resetTerminal:), nil, 0);

    /* View menu */
    m = add_submenu(bar, @"View");
    add_item(m, @"Bigger Font", @selector(biggerFont:), @"=", CMD);
    add_item(m, @"Smaller Font", @selector(smallerFont:), @"-", CMD);
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, @"Enter Full Screen", @selector(toggleFullScreen:),
             @"f", CMD | NSEventModifierFlagControl);

    /* Window menu */
    m = add_submenu(bar, @"Window");
    add_item(m, @"Minimize", @selector(performMiniaturize:), @"m", CMD);
    add_item(m, @"Zoom", @selector(performZoom:), nil, 0);
    [m addItem:[NSMenuItem separatorItem]];
    add_item(m, @"Bring All to Front", @selector(arrangeInFront:), nil, 0);
    NSApp.windowsMenu = m;

    NSApp.mainMenu = bar;
}

/* ----------------------------------------------------------------------
 * main().
 */

static void setup_locale(void)
{
    /*
     * An app started from the Finder has no LANG in its environment,
     * which would leave us in the C locale and unable to convert
     * anything outside ASCII. macOS is UTF-8 throughout, so fall back
     * to that.
     */
    const char *loc = setlocale(LC_CTYPE, "");
    if (!loc || !strcmp(loc, "C") || !strcmp(loc, "POSIX") ||
        MB_CUR_MAX < 2) {
        if (!setlocale(LC_CTYPE, "UTF-8"))
            setlocale(LC_CTYPE, "en_US.UTF-8");
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        setup_locale();

        /*
         * Strip arguments that the system adds when it starts an app,
         * which aren't for us: -psn_* from older versions of the
         * Finder, and the -NS* / -Apple* defaults overrides.
         */
        int nargs = 1;
        char **args = snewn(argc + 1, char *);
        args[0] = argv[0];
        for (int i = 1; i < argc; i++) {
            if (!strncmp(argv[i], "-psn_", 5))
                continue;
            if ((!strncmp(argv[i], "-NS", 3) ||
                 !strncmp(argv[i], "-Apple", 6)) && i+1 < argc) {
                i++;
                continue;
            }
            args[nargs++] = argv[i];
        }
        args[nargs] = NULL;

        sk_init();
        enable_dit();
        settings_set_default_protocol(be_default_protocol);
        {
            const struct BackendVtable *vt =
                backend_vt_from_proto(be_default_protocol);
            settings_set_default_port(0); /* illegal */
            if (vt)
                settings_set_default_port(vt->default_port);
        }

        Conf *conf = conf_new();
        if (do_cmdline(nargs, args, false, conf))
            exit(1);                   /* pre-defaults pass */
        do_defaults(NULL, conf);
        if (do_cmdline(nargs, args, true, conf))
            exit(1);                   /* post-defaults, do everything */
        cmdline_run_saved(conf);
        startup_conf = conf;
        startup_config_box = !cmdline_host_ok(conf);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        static PTAppDelegate *delegate;   /* NSApp.delegate is weak */
        delegate = [[PTAppDelegate alloc] init];
        NSApp.delegate = delegate;
        build_menus(delegate);

        macos_eventloop_setup();

        [NSApp run];
    }
    return 0;
}
