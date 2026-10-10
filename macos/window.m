/*
 * window.m: the terminal window of the native macOS front end.
 *
 * Each session has a PTSession object, which owns the NSWindow, the
 * terminal view, the Terminal, the backend and so on, and implements
 * PuTTY's Seat, TermWin and LogPolicy interfaces through a C struct
 * (MacFrontend) embedded in it.
 *
 * Text is drawn into an off-screen bitmap as the terminal asks for
 * it, and the view copies the bitmap to the screen when Cocoa asks it
 * to redraw, much as the GTK front end uses a backing surface.
 */

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>

#include <assert.h>
#include <math.h>

#include "putty.h"
#include "terminal.h"
#include "storage.h"
#include "macputty.h"

/* Virtual key codes from the Carbon headers, which we don't import. */
enum {
    VK_Return = 0x24, VK_Tab = 0x30, VK_Space = 0x31, VK_Delete = 0x33,
    VK_Escape = 0x35, VK_ForwardDelete = 0x75, VK_Help = 0x72,
    VK_Home = 0x73, VK_End = 0x77, VK_PageUp = 0x74, VK_PageDown = 0x79,
    VK_LeftArrow = 0x7B, VK_RightArrow = 0x7C, VK_DownArrow = 0x7D,
    VK_UpArrow = 0x7E,
    VK_F1 = 0x7A, VK_F2 = 0x78, VK_F3 = 0x63, VK_F4 = 0x76, VK_F5 = 0x60,
    VK_F6 = 0x61, VK_F7 = 0x62, VK_F8 = 0x64, VK_F9 = 0x65, VK_F10 = 0x6D,
    VK_F11 = 0x67, VK_F12 = 0x6F, VK_F13 = 0x69, VK_F14 = 0x6B,
    VK_F15 = 0x71, VK_F16 = 0x6A, VK_F17 = 0x40, VK_F18 = 0x4F,
    VK_F19 = 0x50, VK_F20 = 0x5A,
    VK_KeypadDecimal = 0x41, VK_KeypadMultiply = 0x43, VK_KeypadPlus = 0x45,
    VK_KeypadClear = 0x47, VK_KeypadDivide = 0x4B, VK_KeypadEnter = 0x4C,
    VK_KeypadMinus = 0x4E, VK_KeypadEquals = 0x51,
    VK_Keypad0 = 0x52, VK_Keypad1 = 0x53, VK_Keypad2 = 0x54,
    VK_Keypad3 = 0x55, VK_Keypad4 = 0x56, VK_Keypad5 = 0x57,
    VK_Keypad6 = 0x58, VK_Keypad7 = 0x59, VK_Keypad8 = 0x5B,
    VK_Keypad9 = 0x5C,
};

/* How many lines a notch of a traditional mouse wheel scrolls. */
#define SCROLL_INCREMENT_LINES 5

struct MacFrontend {
    Seat seat;
    TermWin termwin;
    LogPolicy logpolicy;
    void *session;                     /* PTSession, not retained */
};

@class PTTermView;

@interface PTSession : NSObject <NSWindowDelegate, NSMenuDelegate>
{
@public
    MacFrontend fe;
    Conf *conf;
    Terminal *term;
    Backend *backend;
    Ldisc *ldisc;
    LogContext *logctx;
    eventlog_stuff *eventlogstuff;
    struct unicode_data ucsdata;
    cmdline_get_passwd_input_state cmdline_get_passwd_state;
    bool exited;
    bool closing;

    /* Fonts and metrics, in points */
    CTFontRef font, boldfont;          /* boldfont NULL => shadow bold */
    CGFloat font_width, font_ascent, font_xheight;
    int font_height;
    int shadowboldoffset;
    NSMutableDictionary *fallback_fonts;

    /* Cached things out of conf that we refer to a lot */
    int bold_style, window_border, cursor_type;
    bool option_meta, command_meta;

    rgb palette[OSC4_NCOLOURS];

    /* The off-screen bitmap */
    CGContextRef backing;
    CGFloat backing_scale;
    CGFloat backing_w, backing_h;      /* in points */

    bool send_raw_mouse, pointer_indicates_raw_mouse;
    BusyStatus busy_status;
    CGFloat cumulative_vscroll, cumulative_hscroll;
    NSRect cursor_rect;                /* for the input method */

    int width, height;                 /* terminal size in characters */
    bool ignore_resize;
    char *wintitle, *icontitle;

    /* Dialogs we've put up on behalf of the session */
    NSMutableArray *dialogs;
    bool reconfiguring;
}
@property (strong) NSWindow *window;
@property (strong) PTTermView *view;
@property (strong) NSScroller *scroller;
@property (strong) NSView *container;

- (void)layoutSubviews;
- (void)viewSizeChanged;
- (void)keyDown:(NSEvent *)ev;
- (NSMenu *)contextMenu;
- (void)fillSpecialsMenu:(NSMenu *)menu;
- (bool)wantsQuitConfirmation;
@end

@interface PTTermView : NSView <NSTextInputClient>
@property (weak) PTSession *session;
@property (copy) NSString *markedString;
@end

@interface PTSpecial : NSObject
@property SessionSpecialCode code;
@property int arg;
@end
@implementation PTSpecial
@end

static NSMutableSet *all_sessions;

static inline PTSession *SESS(MacFrontend *fe)
{
    return (__bridge PTSession *)fe->session;
}

static NSString *ns(const char *s)
{
    NSString *ret = s ? [NSString stringWithUTF8String:s] : nil;
    return ret ? ret : @"";
}

/* ----------------------------------------------------------------------
 * Platform defaults, used by settings.c.
 */

FontSpec *macos_default_fontspec(void)
{
    return fontspec_new("Menlo 12");
}

FontSpec *platform_default_fontspec(const char *name)
{
    if (!strcmp(name, "Font"))
        return macos_default_fontspec();
    else
        return fontspec_new_default();
}

Filename *platform_default_filename(const char *name)
{
    if (!strcmp(name, "LogFileName"))
        return filename_from_str("putty.log");
    else
        return filename_from_str("");
}

char *platform_default_s(const char *name)
{
    if (!strcmp(name, "SerialLine"))
        return dupstr("/dev/cu.usbserial");
    return NULL;
}

bool platform_default_b(const char *name, bool def)
{
    if (!strcmp(name, "WinNameAlways")) {
        /* Minimised windows can show their own (icon) title */
        return false;
    }
    return def;
}

int platform_default_i(const char *name, int def)
{
    if (!strcmp(name, "CloseOnExit"))
        return 2;  /* maps to FORCE_ON after painful rearrangement :-( */
    return def;
}

/* ----------------------------------------------------------------------
 * Fonts.
 */

/*
 * Font names are stored as "<name> <size>", where <name> is a
 * PostScript name ("Menlo-Regular") or a family name ("Menlo"). For
 * the benefit of settings shared with the GTK version, a "client:"
 * prefix is ignored; GTK's "server:" (X11 bitmap) fonts don't exist
 * here, so those fall back to the default font.
 */
static CTFontRef font_from_name(const char *spec, CGFloat *size_out)
{
    NSString *str = ns(spec);
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    if ([str hasPrefix:@"client:"])
        str = [str substringFromIndex:7];
    else if ([str hasPrefix:@"server:"])
        str = @"";
    str = [str stringByTrimmingCharactersInSet:ws];

    CGFloat size = 0;
    NSRange r = [str rangeOfCharacterFromSet:ws options:NSBackwardsSearch];
    NSString *last = (r.location == NSNotFound ? str :
                      [str substringFromIndex:r.location + 1]);
    NSCharacterSet *notnum = [[NSCharacterSet characterSetWithCharactersInString:
                                   @"0123456789."] invertedSet];
    if (last.length && [last rangeOfCharacterFromSet:notnum].location ==
        NSNotFound) {
        size = last.doubleValue;
        str = (r.location == NSNotFound ? @"" :
               [[str substringToIndex:r.location]
                   stringByTrimmingCharactersInSet:ws]);
    }
    if (size < 4 || size > 400)
        size = 12;
    if (size_out)
        *size_out = size;

    NSFont *f = nil;
    if (str.length) {
        f = [NSFont fontWithName:str size:size];
        if (!f)
            f = [[NSFontManager sharedFontManager]
                    fontWithFamily:str traits:0 weight:5 size:size];
    }
    if (!f)
        return NULL;
    return (CTFontRef)CFBridgingRetain(f);
}

static CTFontRef default_font(CGFloat size)
{
    NSFont *f = [NSFont fontWithName:@"Menlo-Regular" size:size];
    if (!f)
        f = [NSFont userFixedPitchFontOfSize:size];
    return (CTFontRef)CFBridgingRetain(f);
}

static void cache_conf_values(PTSession *s)
{
    s->bold_style = conf_get_int(s->conf, CONF_bold_style);
    s->window_border = conf_get_int(s->conf, CONF_window_border);
    s->cursor_type = conf_get_int(s->conf, CONF_cursor_type);
    s->option_meta = conf_get_bool(s->conf, CONF_osx_option_meta);
    s->command_meta = conf_get_bool(s->conf, CONF_osx_command_meta);
    s->shadowboldoffset = conf_get_int(s->conf, CONF_shadowboldoffset);
}

/*
 * Set up the fonts and the Unicode tables from conf. Returns an error
 * message, or NULL on success.
 */
static char *setup_fonts_ucs(PTSession *s)
{
    FontSpec *fs = conf_get_fontspec(s->conf, CONF_font);
    CGFloat size;
    CTFontRef f = font_from_name(fs->name, &size);
    if (!f)
        f = default_font(size);
    if (!f)
        return dupprintf("unable to load font \"%s\"", fs->name);

    CTFontRef bf = NULL;
    if (!conf_get_bool(s->conf, CONF_shadowbold)) {
        bf = CTFontCreateCopyWithSymbolicTraits(
            f, 0, NULL, kCTFontTraitBold, kCTFontTraitBold);
    }

    if (s->font)
        CFRelease(s->font);
    if (s->boldfont)
        CFRelease(s->boldfont);
    s->font = f;
    s->boldfont = bf;
    s->fallback_fonts = [NSMutableDictionary dictionary];

    UniChar m = 'M';
    CGGlyph g;
    CGSize adv;
    if (CTFontGetGlyphsForCharacters(f, &m, &g, 1)) {
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal,
                                   &g, &adv, 1);
        s->font_width = adv.width;
    } else {
        s->font_width = CTFontGetSize(f) * 0.6;
    }
    if (s->font_width < 1)
        s->font_width = 1;
    CGFloat ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f);
    CGFloat leading = CTFontGetLeading(f);
    s->font_height = (int)ceil(ascent + descent + leading);
    s->font_ascent = round(ascent + leading / 2);
    s->font_xheight = CTFontGetXHeight(f);

    init_ucs(&s->ucsdata, conf_get_str(s->conf, CONF_line_codepage),
             conf_get_bool(s->conf, CONF_utf8_override), CS_UTF8,
             conf_get_int(s->conf, CONF_vtmode));
    return NULL;
}

/* Find a font that can display a character our main font lacks. */
static CTFontRef fallback_font(PTSession *s, CTFontRef base,
                               const UniChar *u, int nu)
{
    unsigned key = (nu == 2 ? 0x10000 + ((u[0] - 0xD800) << 10) +
                    (u[1] - 0xDC00) : u[0]);
    NSNumber *k = @((base == s->boldfont ? 0x80000000U : 0) | key);
    id cached = s->fallback_fonts[k];
    if (cached)
        return (cached == [NSNull null] ? NULL :
                (__bridge CTFontRef)cached);

    CFStringRef str = CFStringCreateWithCharacters(NULL, u, nu);
    CTFontRef fb = CTFontCreateForString(base, str, CFRangeMake(0, nu));
    CFRelease(str);
    if (fb) {
        CGGlyph g[2] = { 0, 0 };
        if (!CTFontGetGlyphsForCharacters(fb, u, g, nu) || !g[0]) {
            CFRelease(fb);
            fb = NULL;
        }
    }
    s->fallback_fonts[k] = fb ? (id)CFBridgingRelease(fb) : [NSNull null];
    return fb;
}

/* ----------------------------------------------------------------------
 * Drawing.
 */

static inline CGFloat colx(PTSession *s, int col)
{
    CGFloat v = s->window_border + col * s->font_width;
    return round(v * s->backing_scale) / s->backing_scale;
}

/* The y coordinate (in the unflipped bitmap) of the top of a row. */
static inline CGFloat rowtop(PTSession *s, int row)
{
    return s->backing_h - (s->window_border + row * s->font_height);
}

static void set_fill_colour(PTSession *s, int col, bool dim)
{
    CGFloat r = s->palette[col].r / 255.0, g = s->palette[col].g / 255.0;
    CGFloat b = s->palette[col].b / 255.0;
    if (dim) {
        r = r * 2 / 3;
        g = g * 2 / 3;
        b = b * 2 / 3;
    }
    CGContextSetRGBFillColor(s->backing, r, g, b, 1.0);
}

static void set_fill_rgb(PTSession *s, optionalrgb c, bool dim)
{
    CGFloat r = c.r / 255.0, g = c.g / 255.0, b = c.b / 255.0;
    if (dim) {
        r = r * 2 / 3;
        g = g * 2 / 3;
        b = b * 2 / 3;
    }
    CGContextSetRGBFillColor(s->backing, r, g, b, 1.0);
}

/* Mark a rectangle of the bitmap (in bitmap coordinates) for redraw. */
static void invalidate_backing_rect(PTSession *s, CGRect r)
{
    NSView *v = s.view;
    CGFloat yoff = v.bounds.size.height - s->backing_h;
    [v setNeedsDisplayInRect:NSInsetRect(NSOffsetRect(r, 0, yoff), -1, -1)];
}

static void draw_backing_rect(PTSession *s)
{
    if (!s->backing)
        return;
    set_fill_colour(s, OSC4_COLOUR_bg, false);
    CGContextFillRect(s->backing,
                      CGRectMake(0, 0, s->backing_w, s->backing_h));
    [s.view setNeedsDisplay:YES];
}

/*
 * (Re)create the bitmap to match the view's current size and scale.
 */
static void setup_backing(PTSession *s)
{
    PTTermView *v = s.view;
    if (!v)
        return;
    CGFloat scale = v.window ? v.window.backingScaleFactor :
        [NSScreen mainScreen].backingScaleFactor;
    if (scale <= 0)
        scale = 1;
    NSSize sz = v.bounds.size;
    size_t pw = (size_t)ceil(sz.width * scale);
    size_t ph = (size_t)ceil(sz.height * scale);
    if (pw < 1) pw = 1;
    if (ph < 1) ph = 1;

    if (s->backing && s->backing_scale == scale &&
        CGBitmapContextGetWidth(s->backing) == pw &&
        CGBitmapContextGetHeight(s->backing) == ph)
        return;

    if (s->backing)
        CGContextRelease(s->backing);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    s->backing = CGBitmapContextCreate(
        NULL, pw, ph, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!s->backing)
        return;
    CGContextScaleCTM(s->backing, scale, scale);
    CGContextSetTextMatrix(s->backing, CGAffineTransformIdentity);
    CGContextSetAllowsFontSmoothing(s->backing, true);
    CGContextSetShouldSmoothFonts(s->backing, true);
    s->backing_scale = scale;
    s->backing_w = pw / scale;
    s->backing_h = ph / scale;

    draw_backing_rect(s);
    if (s->term)
        term_invalidate(s->term);
}

static void draw_chars(PTSession *s, CTFontRef font, const wchar_t *text,
                       int len, int x, int widefactor, CGFloat baseline)
{
    CGContextRef ctx = s->backing;
    CGGlyph *glyphs = snewn(len ? len : 1, CGGlyph);
    CGPoint *pos = snewn(len ? len : 1, CGPoint);
    int n = 0;

    for (int i = 0; i < len; i++) {
        unsigned ch = text[i];
        UniChar u[2];
        int nu;
        if (ch == ' ' || ch == 0)
            continue;
        if (ch >= 0x10000 && ch <= 0x10FFFF) {
            u[0] = 0xD800 + ((ch - 0x10000) >> 10);
            u[1] = 0xDC00 + ((ch - 0x10000) & 0x3FF);
            nu = 2;
        } else {
            u[0] = (ch < 0x10000 && (ch < 0xD800 || ch > 0xDFFF)) ?
                ch : 0xFFFD;
            nu = 1;
        }
        CGPoint p = CGPointMake(colx(s, x + i * widefactor), baseline);
        CGGlyph g[2] = { 0, 0 };
        if (CTFontGetGlyphsForCharacters(font, u, g, nu) && g[0]) {
            glyphs[n] = g[0];
            pos[n] = p;
            n++;
        } else {
            CTFontRef fb = fallback_font(s, font, u, nu);
            if (fb && CTFontGetGlyphsForCharacters(fb, u, g, nu) && g[0])
                CTFontDrawGlyphs(fb, g, &p, 1, ctx);
        }
    }
    if (n)
        CTFontDrawGlyphs(font, glyphs, pos, n, ctx);
    sfree(glyphs);
    sfree(pos);
}

static void draw_combining(PTSession *s, CTFontRef font, const wchar_t *text,
                           int len, int x, CGFloat baseline)
{
    NSString *str = [[NSString alloc]
                        initWithBytes:text length:len * sizeof(wchar_t)
                             encoding:NSUTF32LittleEndianStringEncoding];
    if (!str)
        return;
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorFromContextAttributeName: @YES,
    };
    NSAttributedString *as = [[NSAttributedString alloc]
                                 initWithString:str attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)as);
    CGContextSetTextMatrix(s->backing, CGAffineTransformIdentity);
    CGContextSetTextPosition(s->backing, colx(s, x), baseline);
    CTLineDraw(line, s->backing);
    CFRelease(line);
}

/*
 * Draw a run of text in the bitmap, at given character coordinates,
 * in given attributes. Returns the screen rectangle touched, or a
 * null rectangle if nothing was drawn.
 */
static CGRect do_text_internal(PTSession *s, int x, int y, wchar_t *text,
                               int len, unsigned long attr, int lattr,
                               truecolour tc)
{
    CGContextRef ctx = s->backing;
    int ncombining = 1;

    if (attr & TATTR_COMBINING) {
        ncombining = len;
        len = 1;
    }

    int nfg = (attr & ATTR_FGMASK) >> ATTR_FGSHIFT;
    int nbg = (attr & ATTR_BGMASK) >> ATTR_BGSHIFT;
    if (attr & ATTR_REVERSE) {
        int t = nfg;
        nfg = nbg;
        nbg = t;
        optionalrgb trgb = tc.fg;
        tc.fg = tc.bg;
        tc.bg = trgb;
    }
    if ((s->bold_style & BOLD_STYLE_COLOUR) && (attr & ATTR_BOLD)) {
        if (nfg < 16) nfg |= 8;
        else if (nfg >= 256) nfg |= 1;
    }
    if ((s->bold_style & BOLD_STYLE_COLOUR) && (attr & ATTR_BLINK)) {
        if (nbg < 16) nbg |= 8;
        else if (nbg >= 256) nbg |= 1;
    }
    if (attr & ATTR_ACTCURS) {
        tc.fg = tc.bg = optionalrgb_none;
        nfg = OSC4_COLOUR_cursor_fg;
        nbg = OSC4_COLOUR_cursor_bg;
        attr &= ~ATTR_DIM;             /* don't dim the cursor */
    }

    int widefactor = (attr & ATTR_WIDE) ? 2 : 1;
    bool bold = (attr & ATTR_BOLD) && (s->bold_style & BOLD_STYLE_FONT);
    int mode = lattr & LATTR_MODE;

    int sx = x, scols;
    if (mode != LATTR_NORM) {
        sx = x * 2;
        if (sx >= s->term->cols)
            return CGRectNull;
        if (sx + len * 2 * widefactor > s->term->cols) {
            len = (s->term->cols - sx) / 2 / widefactor; /* trim to LH half */
            if (len == 0)
                return CGRectNull;
        }
        scols = len * 2 * widefactor;
    } else {
        scols = len * widefactor;
    }

    CGFloat top = rowtop(s, y), bottom = top - s->font_height;
    CGRect screenrect = CGRectMake(colx(s, sx), bottom,
                                   colx(s, sx + scols) - colx(s, sx),
                                   s->font_height);

    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, screenrect);

    if (mode != LATTR_NORM) {
        /* Stretch horizontally about the left border, and (for the
         * double-height modes) vertically about the top or bottom of
         * the row, so that the right half of a double-height
         * character is clipped away. */
        CGFloat b = s->window_border;
        CGContextTranslateCTM(ctx, b, 0);
        CGContextScaleCTM(ctx, 2, 1);
        CGContextTranslateCTM(ctx, -b, 0);
        if (mode == LATTR_TOP) {
            CGContextTranslateCTM(ctx, 0, top);
            CGContextScaleCTM(ctx, 1, 2);
            CGContextTranslateCTM(ctx, 0, -top);
        } else if (mode == LATTR_BOT) {
            CGContextTranslateCTM(ctx, 0, bottom);
            CGContextScaleCTM(ctx, 1, 2);
            CGContextTranslateCTM(ctx, 0, -bottom);
        }
    }

    CGFloat lx = colx(s, x), rx = colx(s, x + len * widefactor);

    if (tc.bg.enabled)
        set_fill_rgb(s, tc.bg, attr & ATTR_DIM);
    else
        set_fill_colour(s, nbg, attr & ATTR_DIM);
    CGContextFillRect(ctx, CGRectMake(lx, bottom, rx - lx, s->font_height));

    if (tc.fg.enabled)
        set_fill_rgb(s, tc.fg, attr & ATTR_DIM);
    else
        set_fill_colour(s, nfg, attr & ATTR_DIM);

    CTFontRef f = (bold && s->boldfont) ? s->boldfont : s->font;
    bool shadow = bold && !s->boldfont;
    CGFloat baseline = top - s->font_ascent;
    for (int pass = 0; pass < (shadow ? 2 : 1); pass++) {
        if (pass == 1) {
            CGContextTranslateCTM(ctx, s->shadowboldoffset > 0 ?
                                  s->shadowboldoffset : 1, 0);
        }
        if (ncombining > 1)
            draw_combining(s, f, text, ncombining, x, baseline);
        else
            draw_chars(s, f, text, len, x, widefactor, baseline);
    }
    if (shadow)
        CGContextTranslateCTM(ctx, -(s->shadowboldoffset > 0 ?
                                     s->shadowboldoffset : 1), 0);

    CGFloat lw = fmax(1.0 / s->backing_scale, round(CTFontGetSize(s->font) /
                                                     14.0));
    if (attr & ATTR_UNDER) {
        CGFloat uheight = s->font_ascent + 1;
        if (uheight >= s->font_height)
            uheight = s->font_height - 1;
        CGContextFillRect(ctx, CGRectMake(lx, top - uheight - lw,
                                          rx - lx, lw));
    }
    if (attr & ATTR_STRIKE) {
        CGFloat sy = baseline + s->font_xheight / 2;
        CGContextFillRect(ctx, CGRectMake(lx, sy - lw / 2, rx - lx, lw));
    }

    CGContextRestoreGState(ctx);
    return screenrect;
}

static bool mac_setup_draw_ctx(TermWin *tw)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    return s->backing != NULL;
}

static void mac_free_draw_ctx(TermWin *tw)
{
}

static void mac_draw_text(TermWin *tw, int x, int y, wchar_t *text, int len,
                          unsigned long attr, int lattr, truecolour tc)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    CGRect r = do_text_internal(s, x, y, text, len, attr, lattr, tc);
    if (!CGRectIsNull(r))
        invalidate_backing_rect(s, r);
}

static void mac_draw_cursor(TermWin *tw, int x, int y, wchar_t *text,
                            int len, unsigned long attr, int lattr,
                            truecolour tc)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    CGContextRef ctx = s->backing;
    bool active, passive;

    if (attr & ATTR_PASCURS) {
        attr &= ~ATTR_PASCURS;
        passive = true;
    } else
        passive = false;
    if ((attr & ATTR_ACTCURS) && s->cursor_type != CURSOR_BLOCK) {
        attr &= ~ATTR_ACTCURS;
        active = true;
    } else
        active = false;

    CGRect r = do_text_internal(s, x, y, text, len, attr, lattr, tc);
    if (CGRectIsNull(r))
        return;

    CGFloat px = 1.0 / s->backing_scale;
    CGFloat top = CGRectGetMaxY(r);
    CGFloat lw = fmax(px, 1.0);
    int widefactor = (attr & ATTR_WIDE) ? 2 : 1;
    CGFloat char_width = s->font_width *
        (((attr & ATTR_WIDE) || (lattr & LATTR_MODE) != LATTR_NORM) ? 2 : 1);

    CGContextSaveGState(ctx);
    set_fill_colour(s, OSC4_COLOUR_cursor_bg, false);
    CGContextSetRGBStrokeColor(
        ctx, s->palette[OSC4_COLOUR_cursor_bg].r / 255.0,
        s->palette[OSC4_COLOUR_cursor_bg].g / 255.0,
        s->palette[OSC4_COLOUR_cursor_bg].b / 255.0, 1.0);

    if (s->cursor_type == CURSOR_BLOCK) {
        /* An active block cursor was done by do_text_internal; only a
         * passive one needs drawing here, as a hollow box. */
        if (passive) {
            CGContextSetLineWidth(ctx, lw);
            CGContextStrokeRect(ctx, CGRectInset(r, lw / 2, lw / 2));
        }
    } else {
        CGRect line;
        if (s->cursor_type == CURSOR_UNDERLINE) {
            CGFloat uheight = s->font_ascent + 1;
            if (uheight >= s->font_height)
                uheight = s->font_height - 1;
            line = CGRectMake(r.origin.x, top - uheight - lw,
                              (attr & TATTR_COMBINING ? 1 : len) *
                              widefactor * char_width, lw);
            if (line.size.width > r.size.width)
                line.size.width = r.size.width;
        } else {                       /* CURSOR_VERTICAL_LINE */
            CGFloat xadjust = 0;
            if (attr & ATTR_RIGHTCURS)
                xadjust = char_width - lw;
            line = CGRectMake(r.origin.x + xadjust, r.origin.y, lw,
                              r.size.height);
        }
        if (passive) {
            /* dotted */
            bool horiz = line.size.width > line.size.height;
            CGFloat len_ = horiz ? line.size.width : line.size.height;
            for (CGFloat d = 0; d < len_; d += 2 * lw) {
                CGRect dot = horiz ?
                    CGRectMake(line.origin.x + d, line.origin.y, lw, lw) :
                    CGRectMake(line.origin.x, line.origin.y + d, lw, lw);
                CGContextFillRect(ctx, dot);
            }
        } else if (active) {
            CGContextFillRect(ctx, line);
        }
    }
    CGContextRestoreGState(ctx);

    invalidate_backing_rect(s, r);

    /* Remember where the cursor is, for input methods. */
    CGFloat yoff = s.view.bounds.size.height - s->backing_h;
    s->cursor_rect = NSOffsetRect(r, 0, yoff);
}

extern const struct RgbIconImage *const main_icon_rgb[];
extern const int n_main_icon_rgb;

static CGImageRef trust_sigil_image(void)
{
    static CGImageRef img;
    if (!img) {
        /* Take the biggest icon, and let CG scale it down. */
        const struct RgbIconImage *best = main_icon_rgb[0];
        for (int i = 1; i < n_main_icon_rgb; i++)
            if (main_icon_rgb[i]->width > best->width)
                best = main_icon_rgb[i];
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef dp = CGDataProviderCreateWithData(
            NULL, best->data, 4 * best->width * best->height, NULL);
        img = CGImageCreate(best->width, best->height, 8, 32,
                            4 * best->width, cs,
                            kCGImageAlphaLast | kCGBitmapByteOrderDefault,
                            dp, NULL, true, kCGRenderingIntentDefault);
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
    }
    return img;
}

static void mac_draw_trust_sigil(TermWin *tw, int cx, int cy)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    CGFloat top = rowtop(s, cy);
    CGFloat h = s->font_height, w = colx(s, cx + 2) - colx(s, cx);
    CGFloat side = fmin(w, h);
    CGRect r = CGRectMake(colx(s, cx) + (w - side) / 2,
                          top - h + (h - side) / 2, side, side);
    CGImageRef img = trust_sigil_image();
    if (img) {
        CGContextSetInterpolationQuality(s->backing, kCGInterpolationHigh);
        CGContextDrawImage(s->backing, r, img);
    }
    invalidate_backing_rect(s, CGRectMake(colx(s, cx), top - h, w, h));
}

static int mac_char_width(TermWin *tw, int uc)
{
    /* Wide characters are drawn across two cells; the terminal
     * decides which those are. */
    return 1;
}

/* ----------------------------------------------------------------------
 * The rest of the TermWin implementation.
 */

static void mac_set_cursor_pos(TermWin *tw, int x, int y)
{
    /* The input method asks where the cursor is when it needs to. */
}

static void update_mouseptr(PTSession *s)
{
    [s.window invalidateCursorRectsForView:s.view];
}

static void mac_set_raw_mouse_mode(TermWin *tw, bool enable)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    s->send_raw_mouse = enable;
}

static void mac_set_raw_mouse_mode_pointer(TermWin *tw, bool enable)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    s->pointer_indicates_raw_mouse = enable;
    update_mouseptr(s);
}

static void mac_set_scrollbar(TermWin *tw, int total, int start, int page)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    NSScroller *sc = s.scroller;
    if (!sc)
        return;
    if (total <= page) {
        sc.knobProportion = 1.0;
        sc.doubleValue = 0.0;
        sc.enabled = NO;
    } else {
        sc.enabled = YES;
        sc.knobProportion = (CGFloat)page / total;
        sc.doubleValue = (double)start / (total - page);
    }
}

static void mac_bell(TermWin *tw, int mode)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (mode == BELL_DEFAULT)
        NSBeep();
    if (mode != BELL_DISABLED && !s.window.isKeyWindow)
        [NSApp requestUserAttention:NSInformationalRequest];
}

static void mac_clip_write(TermWin *tw, int clipboard, wchar_t *text,
                           int *attrs, truecolour *colours, int len,
                           bool must_deselect)
{
    if (clipboard != CLIP_CLIPBOARD)
        return;
    NSString *str = [[NSString alloc]
                        initWithBytes:text length:len * sizeof(wchar_t)
                             encoding:NSUTF32LittleEndianStringEncoding];
    if (!str)
        return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:str forType:NSPasteboardTypeString];
}

static void mac_clip_request_paste(TermWin *tw, int clipboard)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (clipboard != CLIP_CLIPBOARD)
        return;
    NSString *str = [[NSPasteboard generalPasteboard]
                        stringForType:NSPasteboardTypeString];
    if (!str)
        return;
    NSData *d = [str dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (!d.length)
        return;
    term_do_paste(s->term, (const wchar_t *)d.bytes,
                  d.length / sizeof(wchar_t));
}

static void mac_refresh(TermWin *tw)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    draw_backing_rect(s);
    term_invalidate(s->term);
}

static NSSize content_size_for(PTSession *s, int w, int h)
{
    CGFloat sbw = 0;
    if (conf_get_bool(s->conf, CONF_scrollbar))
        sbw = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                        scrollerStyle:NSScrollerStyleLegacy];
    return NSMakeSize(ceil(w * s->font_width) + 2 * s->window_border + sbw,
                      h * s->font_height + 2 * s->window_border);
}

static void set_geom_hints(PTSession *s)
{
    NSWindow *win = s.window;
    win.contentResizeIncrements = NSMakeSize(s->font_width, s->font_height);
    win.contentMinSize = content_size_for(s, 2, 1);
}

static void resize_window_to_term(PTSession *s, int w, int h)
{
    NSWindow *win = s.window;
    if (!win)
        return;
    if ((win.styleMask & NSWindowStyleMaskFullScreen) || win.isZoomed) {
        /* The window size is the screen's business; the terminal will
         * be told how big it is when it changes. */
        return;
    }
    NSSize sz = content_size_for(s, w, h);
    NSRect frame = win.frame;
    NSRect newframe = [win frameRectForContentRect:
                               NSMakeRect(0, 0, sz.width, sz.height)];
    /* Keep the top left corner where it is. */
    newframe.origin.x = frame.origin.x;
    newframe.origin.y = NSMaxY(frame) - newframe.size.height;
    if (win.screen)
        newframe = [win constrainFrameRect:newframe toScreen:win.screen];
    [win setFrame:newframe display:YES];
}

static void mac_request_resize(TermWin *tw, int w, int h)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (conf_get_int(s->conf, CONF_resize_action) != RESIZE_DISABLED)
        resize_window_to_term(s, w, h);
    term_resize_request_completed(s->term);
}

static char *title_to_utf8(const char *title, int codepage)
{
    if (codepage != CP_UTF8) {
        wchar_t *title_w = dup_mb_to_wc(codepage, title);
        char *ret = encode_wide_string_as_utf8(title_w);
        sfree(title_w);
        return ret;
    }
    return dupstr(title);
}

static void set_window_titles(PTSession *s)
{
    s.window.title = ns(s->wintitle);
    if (!conf_get_bool(s->conf, CONF_win_name_always) && s->icontitle)
        s.window.miniwindowTitle = ns(s->icontitle);
    else
        s.window.miniwindowTitle = ns(s->wintitle);
}

static void mac_set_title(TermWin *tw, const char *title, int codepage)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    sfree(s->wintitle);
    s->wintitle = title_to_utf8(title, codepage);
    set_window_titles(s);
}

static void mac_set_icon_title(TermWin *tw, const char *title, int codepage)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    sfree(s->icontitle);
    s->icontitle = title_to_utf8(title, codepage);
    set_window_titles(s);
}

static void mac_set_minimised(TermWin *tw, bool minimised)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (minimised)
        [s.window miniaturize:nil];
    else
        [s.window deminiaturize:nil];
}

static void mac_set_maximised(TermWin *tw, bool maximised)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (!!s.window.isZoomed != !!maximised)
        [s.window zoom:nil];
}

static void mac_move(TermWin *tw, int x, int y)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    NSScreen *screen = s.window.screen ? s.window.screen :
        [NSScreen mainScreen];
    /* x,y are relative to the top left of the screen. */
    NSRect sf = screen.frame;
    [s.window setFrameTopLeftPoint:NSMakePoint(sf.origin.x + x,
                                               NSMaxY(sf) - y)];
}

static void mac_set_zorder(TermWin *tw, bool top)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (top)
        [s.window orderFront:nil];
    else
        [s.window orderBack:nil];
}

static void mac_palette_set(TermWin *tw, unsigned start, unsigned ncolours,
                            const rgb *colours)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    assert(start <= OSC4_NCOLOURS);
    assert(ncolours <= OSC4_NCOLOURS - start);
    for (unsigned i = 0; i < ncolours; i++)
        s->palette[start + i] = colours[i];

    if (start <= OSC4_COLOUR_bg && OSC4_COLOUR_bg < start + ncolours) {
        /* The default background has changed, so repaint the border. */
        NSColor *bg = [NSColor colorWithSRGBRed:s->palette[OSC4_COLOUR_bg].r / 255.0
                                          green:s->palette[OSC4_COLOUR_bg].g / 255.0
                                           blue:s->palette[OSC4_COLOUR_bg].b / 255.0
                                          alpha:1.0];
        s.window.backgroundColor = bg;
        draw_backing_rect(s);
        if (s->term)
            term_invalidate(s->term);
    }
}

static void mac_palette_get_overrides(TermWin *tw, Terminal *term)
{
    /* We have no system-wide colour overrides to apply. */
}

static void mac_unthrottle(TermWin *tw, size_t bufsize)
{
    PTSession *s = SESS(container_of(tw, MacFrontend, termwin));
    if (s->backend)
        backend_unthrottle(s->backend, bufsize);
}

static const TermWinVtable mac_termwin_vt = {
    .setup_draw_ctx = mac_setup_draw_ctx,
    .draw_text = mac_draw_text,
    .draw_cursor = mac_draw_cursor,
    .draw_trust_sigil = mac_draw_trust_sigil,
    .char_width = mac_char_width,
    .free_draw_ctx = mac_free_draw_ctx,
    .set_cursor_pos = mac_set_cursor_pos,
    .set_raw_mouse_mode = mac_set_raw_mouse_mode,
    .set_raw_mouse_mode_pointer = mac_set_raw_mouse_mode_pointer,
    .set_scrollbar = mac_set_scrollbar,
    .bell = mac_bell,
    .clip_write = mac_clip_write,
    .clip_request_paste = mac_clip_request_paste,
    .refresh = mac_refresh,
    .request_resize = mac_request_resize,
    .set_title = mac_set_title,
    .set_icon_title = mac_set_icon_title,
    .set_minimised = mac_set_minimised,
    .set_maximised = mac_set_maximised,
    .move = mac_move,
    .set_zorder = mac_set_zorder,
    .palette_set = mac_palette_set,
    .palette_get_overrides = mac_palette_get_overrides,
    .unthrottle = mac_unthrottle,
};

/* ----------------------------------------------------------------------
 * Seat.
 */

static void destroy_inst_connection(PTSession *s);

static void close_after_fatal(void *vctx, int result)
{
    MacFrontend *fe = (MacFrontend *)vctx;
    PTSession *s = SESS(fe);
    if (!s->closing)
        [s.window close];
}

static void connection_fatal_callback(void *vctx)
{
    MacFrontend *fe = (MacFrontend *)vctx;
    destroy_inst_connection(SESS(fe));
}

static void mac_seat_connection_fatal(Seat *seat, const char *msg)
{
    MacFrontend *fe = container_of(seat, MacFrontend, seat);
    PTSession *s = SESS(fe);
    static const char *const ok[] = { "OK" };
    char *title = dupcat(appname, " Fatal Error");
    bool close = conf_get_int(s->conf, CONF_close_on_exit) == FORCE_ON;
    void *box = macos_message_box(
        (__bridge void *)s.window, title, msg, true, ok, 1,
        close ? close_after_fatal : NULL, fe);
    macos_frontend_register_dialog(seat, box);
    sfree(title);

    s->exited = true;   /* suppress normal exit handling */
    queue_toplevel_callback(connection_fatal_callback, fe);
}

static void mac_seat_nonfatal(Seat *seat, const char *msg)
{
    MacFrontend *fe = container_of(seat, MacFrontend, seat);
    static const char *const ok[] = { "OK" };
    char *title = dupcat(appname, " Error");
    void *box = macos_message_box(
        (__bridge void *)SESS(fe).window, title, msg, false, ok, 1,
        NULL, NULL);
    macos_frontend_register_dialog(seat, box);
    sfree(title);
}

static size_t mac_seat_output(Seat *seat, SeatOutputType type,
                              const void *data, size_t len)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    return term_data(s->term, data, len);
}

static bool mac_seat_eof(Seat *seat)
{
    return true;   /* do respond to incoming EOF with outgoing */
}

static SeatPromptResult mac_seat_get_userpass_input(Seat *seat,
                                                    prompts_t *p)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    SeatPromptResult spr;
    spr = cmdline_get_passwd_input(p, &s->cmdline_get_passwd_state, true);
    if (spr.kind == SPRK_INCOMPLETE)
        spr = term_get_userpass_input(s->term, p);
    return spr;
}

static void exit_callback(void *vctx)
{
    MacFrontend *fe = (MacFrontend *)vctx;
    PTSession *s = SESS(fe);
    int exitcode, close_on_exit;

    if (!s->exited && s->backend &&
        (exitcode = backend_exitcode(s->backend)) >= 0) {
        destroy_inst_connection(s);

        close_on_exit = conf_get_int(s->conf, CONF_close_on_exit);
        if (close_on_exit == FORCE_ON ||
            (close_on_exit == AUTO && exitcode == 0)) {
            if (!s->closing)
                [s.window close];
        }
    }
}

static void mac_seat_notify_remote_exit(Seat *seat)
{
    MacFrontend *fe = container_of(seat, MacFrontend, seat);
    queue_toplevel_callback(exit_callback, fe);
}

static void mac_seat_update_specials_menu(Seat *seat)
{
    /* The Special Commands menu is built when it's opened. */
}

static char *mac_seat_get_ttymode(Seat *seat, const char *mode)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    return term_get_ttymode(s->term, mode);
}

static void mac_seat_set_busy_status(Seat *seat, BusyStatus status)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    s->busy_status = status;
    update_mouseptr(s);
}

static bool mac_seat_is_utf8(Seat *seat)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    return s->ucsdata.line_codepage == CS_UTF8;
}

static bool mac_seat_get_window_pixel_size(Seat *seat, int *w, int *h)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    NSSize sz = s.view.bounds.size;
    *w = (int)sz.width;
    *h = (int)sz.height;
    return true;
}

static StripCtrlChars *mac_seat_stripctrl_new(
    Seat *seat, BinarySink *bs_out, SeatInteractionContext sic)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    return stripctrl_new_term(bs_out, false, 0, s->term);
}

static void mac_seat_set_trust_status(Seat *seat, bool trusted)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    term_set_trust_status(s->term, trusted);
}

static bool mac_seat_can_set_trust_status(Seat *seat)
{
    return true;
}

static bool mac_seat_get_cursor_position(Seat *seat, int *x, int *y)
{
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    if (s->term) {
        term_get_cursor_position(s->term, x, y);
        return true;
    }
    return false;
}

static const SeatVtable mac_seat_vt = {
    .output = mac_seat_output,
    .eof = mac_seat_eof,
    .sent = nullseat_sent,
    .banner = nullseat_banner_to_stderr,
    .get_userpass_input = mac_seat_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = mac_seat_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = mac_seat_connection_fatal,
    .nonfatal = mac_seat_nonfatal,
    .update_specials_menu = mac_seat_update_specials_menu,
    .get_ttymode = mac_seat_get_ttymode,
    .set_busy_status = mac_seat_set_busy_status,
    .confirm_ssh_host_key = macos_seat_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = macos_seat_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = macos_seat_confirm_weak_cached_hostkey,
    .prompt_descriptions = macos_seat_prompt_descriptions,
    .is_utf8 = mac_seat_is_utf8,
    .echoedit_update = nullseat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = mac_seat_get_window_pixel_size,
    .stripctrl_new = mac_seat_stripctrl_new,
    .set_trust_status = mac_seat_set_trust_status,
    .can_set_trust_status = mac_seat_can_set_trust_status,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = mac_seat_get_cursor_position,
};

Seat *macos_frontend_seat(MacFrontend *fe)
{
    return &fe->seat;
}

void *macos_frontend_window(MacFrontend *fe)
{
    return (__bridge void *)SESS(fe).window;
}

void *macos_seat_window(Seat *seat)
{
    if (seat->vt != &mac_seat_vt)
        return NULL;
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    return (__bridge void *)s.window;
}

void macos_frontend_register_dialog(Seat *seat, void *box)
{
    if (!box || seat->vt != &mac_seat_vt)
        return;
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    [s->dialogs addObject:(__bridge id)box];
}

void macos_frontend_unregister_dialog(Seat *seat, void *box)
{
    if (!box || seat->vt != &mac_seat_vt)
        return;
    PTSession *s = SESS(container_of(seat, MacFrontend, seat));
    [s->dialogs removeObjectIdenticalTo:(__bridge id)box];
}

/* ----------------------------------------------------------------------
 * LogPolicy.
 */

static void mac_eventlog(LogPolicy *lp, const char *string)
{
    PTSession *s = SESS(container_of(lp, MacFrontend, logpolicy));
    logevent_dlg(s->eventlogstuff, string);
}

static int mac_askappend(LogPolicy *lp, Filename *filename,
                         void (*callback)(void *ctx, int result), void *ctx)
{
    MacFrontend *fe = container_of(lp, MacFrontend, logpolicy);
    return macos_askappend(&fe->seat, filename, callback, ctx);
}

static void mac_logging_error(LogPolicy *lp, const char *event)
{
    MacFrontend *fe = container_of(lp, MacFrontend, logpolicy);

    /* Send 'can't open log file' errors to the terminal window.
     * (Marked as stderr, although terminal.c won't care.) */
    seat_stderr_pl(&fe->seat, ptrlen_from_asciz(event));
    seat_stderr_pl(&fe->seat, PTRLEN_LITERAL("\r\n"));
}

static const LogPolicyVtable mac_logpolicy_vt = {
    .eventlog = mac_eventlog,
    .askappend = mac_askappend,
    .logging_error = mac_logging_error,
    .verbose = null_lp_verbose_yes,
};

/* ----------------------------------------------------------------------
 * Session lifetime.
 */

static void start_backend(PTSession *s)
{
    const struct BackendVtable *vt;
    char *error, *realhost;

    s->cmdline_get_passwd_state = cmdline_get_passwd_input_state_new;

    vt = backend_vt_from_proto(conf_get_int(s->conf, CONF_protocol));
    if (!vt) {
        seat_connection_fatal(&s->fe.seat, "Unsupported protocol");
        s->exited = true;
        return;
    }

    seat_set_trust_status(&s->fe.seat, true);
    error = backend_init(vt, &s->fe.seat, &s->backend,
                         s->logctx, s->conf,
                         conf_get_str(s->conf, CONF_host),
                         conf_get_int(s->conf, CONF_port),
                         &realhost,
                         conf_get_bool(s->conf, CONF_tcp_nodelay),
                         conf_get_bool(s->conf, CONF_tcp_keepalives));

    if (error) {
        seat_connection_fatal(&s->fe.seat,
                              "Unable to open connection to %s:\n%s",
                              conf_dest(s->conf), error);
        sfree(error);
        s->exited = true;
        return;
    }

    term_setup_window_titles(s->term, realhost);
    sfree(realhost);

    term_provide_backend(s->term, s->backend);

    s->ldisc = ldisc_create(s->conf, s->term, s->backend, &s->fe.seat);
}

static void destroy_inst_connection(PTSession *s)
{
    s->exited = true;
    if (s->ldisc) {
        ldisc_free(s->ldisc);
        s->ldisc = NULL;
    }
    if (s->backend) {
        backend_free(s->backend);
        s->backend = NULL;
    }
    if (s->term)
        term_provide_backend(s->term, NULL);
}

static void delete_inst(PTSession *s)
{
    /* Dismiss any dialogs still up on the session's behalf. Each one
     * unregisters itself as it goes. */
    while (s->dialogs.count) {
        id box = s->dialogs.lastObject;
        [s->dialogs removeLastObject];
        macos_cancel_message_box((__bridge void *)box);
    }

    destroy_inst_connection(s);
    if (s->term) {
        term_free(s->term);
        s->term = NULL;
    }
    if (s->logctx) {
        log_free(s->logctx);
        s->logctx = NULL;
    }
    if (s->conf) {
        conf_free(s->conf);
        s->conf = NULL;
    }
    if (s->backing) {
        CGContextRelease(s->backing);
        s->backing = NULL;
    }
    if (s->font) {
        CFRelease(s->font);
        s->font = NULL;
    }
    if (s->boldfont) {
        CFRelease(s->boldfont);
        s->boldfont = NULL;
    }
    sfree(s->wintitle);
    s->wintitle = NULL;
    sfree(s->icontitle);
    s->icontitle = NULL;

    /*
     * Delete any top-level callbacks associated with this session,
     * which would otherwise become stale-pointer dereferences waiting
     * to happen. We do this last, because some of the above cleanups
     * (notably shutting down the backend) might themselves queue such
     * callbacks.
     */
    delete_callbacks_for_context(&s->fe);

    if (s->eventlogstuff) {
        eventlogstuff_free(s->eventlogstuff);
        s->eventlogstuff = NULL;
    }
}

static void setup_clipboards(PTSession *s)
{
    Terminal *term = s->term;
    assert(term->mouse_select_clipboards[0] == CLIP_LOCAL);

    term->n_mouse_select_clipboards = 1;
    if (conf_get_bool(s->conf, CONF_mouseautocopy)) {
        term->mouse_select_clipboards[
            term->n_mouse_select_clipboards++] = CLIP_CLIPBOARD;
    }

    switch (conf_get_int(s->conf, CONF_mousepaste)) {
      case CLIPUI_IMPLICIT:
        term->mouse_paste_clipboard = CLIP_LOCAL;
        break;
      case CLIPUI_EXPLICIT:
        term->mouse_paste_clipboard = CLIP_CLIPBOARD;
        break;
      default:
        term->mouse_paste_clipboard = CLIP_NULL;
        break;
    }
}

/* ----------------------------------------------------------------------
 * The terminal view.
 */

static void show_mouseptr(PTSession *s, bool show)
{
    if (!show && conf_get_bool(s->conf, CONF_hide_mouseptr))
        [NSCursor setHiddenUntilMouseMoves:YES];
}

@implementation PTTermView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return NO; }

- (void)drawRect:(NSRect)dirty
{
    PTSession *s = self.session;
    CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
    if (!s || !s->backing) {
        [[NSColor blackColor] setFill];
        NSRectFill(dirty);
        return;
    }
    CGImageRef img = CGBitmapContextCreateImage(s->backing);
    if (!img)
        return;
    CGFloat h = self.bounds.size.height;
    CGContextSaveGState(ctx);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, h - s->backing_h, s->backing_w,
                                       s->backing_h), img);
    CGContextRestoreGState(ctx);
    CGImageRelease(img);

    if (self.bounds.size.height > s->backing_h ||
        self.bounds.size.width > s->backing_w) {
        /* Any sliver not covered by the bitmap gets the background. */
        set_fill_colour(s, OSC4_COLOUR_bg, false);
    }
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    PTSession *s = self.session;
    if (s)
        setup_backing(s);
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    PTSession *s = self.session;
    if (s)
        setup_backing(s);
}

- (void)resetCursorRects
{
    PTSession *s = self.session;
    NSCursor *c = (s && s->pointer_indicates_raw_mouse) ?
        [NSCursor arrowCursor] : [NSCursor IBeamCursor];
    [self addCursorRect:self.bounds cursor:c];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas)
        [self removeTrackingArea:a];
    NSTrackingArea *a = [[NSTrackingArea alloc]
                            initWithRect:NSZeroRect
                                 options:(NSTrackingMouseMoved |
                                          NSTrackingActiveInKeyWindow |
                                          NSTrackingInVisibleRect)
                                   owner:self userInfo:nil];
    [self addTrackingArea:a];
}

/* --- Mouse --- */

- (void)cellForEvent:(NSEvent *)ev x:(int *)x y:(int *)y
{
    PTSession *s = self.session;
    NSPoint p = [self convertPoint:ev.locationInWindow fromView:nil];
    CGFloat top = self.bounds.size.height - p.y;
    *x = (int)floor((p.x - s->window_border) / s->font_width);
    *y = (int)floor((top - s->window_border) / s->font_height);
}

- (bool)metaForFlags:(NSEventModifierFlags)mods
{
    PTSession *s = self.session;
    return ((mods & NSEventModifierFlagOption) && s->option_meta) ||
        ((mods & NSEventModifierFlagCommand) && s->command_meta);
}

static Mouse_Button translate_button(Mouse_Button button)
{
    if (button == MBT_LEFT)
        return MBT_SELECT;
    if (button == MBT_MIDDLE)
        return MBT_PASTE;
    if (button == MBT_RIGHT)
        return MBT_EXTEND;
    if (button == MBT_NOTHING)
        return MBT_NOTHING;
    return 0;                          /* shouldn't happen */
}

- (bool)rawMouseMode:(NSEvent *)ev
{
    PTSession *s = self.session;
    bool shift = ev.modifierFlags & NSEventModifierFlagShift;
    return s->send_raw_mouse &&
        !(shift && conf_get_bool(s->conf, CONF_mouse_override));
}

- (void)buttonEvent:(NSEvent *)ev button:(Mouse_Button)button
             action:(Mouse_Action)act
{
    PTSession *s = self.session;
    if (!s || !s->term)
        return;
    NSEventModifierFlags mods = ev.modifierFlags;
    int x, y;
    [self cellForEvent:ev x:&x y:&y];
    bool shift = mods & NSEventModifierFlagShift;
    bool ctrl = mods & NSEventModifierFlagControl;
    bool alt = [self metaForFlags:mods];

    noise_ultralight(NOISE_SOURCE_MOUSEBUTTON, button);
    show_mouseptr(s, true);

    term_mouse(s->term, button, translate_button(button), act,
               x, y, shift, ctrl, alt);

    /* Like GTK, follow the press with a separate multi-click event,
     * except in raw mouse mode where they aren't wanted. */
    if (act == MA_CLICK && ev.clickCount >= 2 && ![self rawMouseMode:ev]) {
        term_mouse(s->term, button, translate_button(button),
                   ev.clickCount == 2 ? MA_2CLK : MA_3CLK,
                   x, y, shift, ctrl, alt);
    }
}

- (bool)maybePopupMenu:(NSEvent *)ev
{
    PTSession *s = self.session;
    if (!s)
        return false;
    if (!(ev.modifierFlags & NSEventModifierFlagControl))
        return false;
    term_cancel_selection_drag(s->term);
    [NSMenu popUpContextMenu:[s contextMenu] withEvent:ev forView:self];
    return true;
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    /* We pop the menu up ourselves, on Ctrl-click, so that plain
     * right-clicks can go to the terminal. */
    return nil;
}

- (void)mouseDown:(NSEvent *)ev
{
    if ([self maybePopupMenu:ev])
        return;
    [self buttonEvent:ev button:MBT_LEFT action:MA_CLICK];
}
- (void)mouseUp:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_LEFT action:MA_RELEASE];
}
- (void)mouseDragged:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_LEFT action:MA_DRAG];
}
- (void)rightMouseDown:(NSEvent *)ev
{
    if ([self maybePopupMenu:ev])
        return;
    [self buttonEvent:ev button:MBT_RIGHT action:MA_CLICK];
}
- (void)rightMouseUp:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_RIGHT action:MA_RELEASE];
}
- (void)rightMouseDragged:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_RIGHT action:MA_DRAG];
}
- (void)otherMouseDown:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_MIDDLE action:MA_CLICK];
}
- (void)otherMouseUp:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_MIDDLE action:MA_RELEASE];
}
- (void)otherMouseDragged:(NSEvent *)ev
{
    [self buttonEvent:ev button:MBT_MIDDLE action:MA_DRAG];
}

- (void)mouseMoved:(NSEvent *)ev
{
    PTSession *s = self.session;
    if (!s || !s->term)
        return;
    NSPoint p = ev.locationInWindow;
    noise_ultralight(NOISE_SOURCE_MOUSEPOS,
                     ((uint32_t)p.x << 16) | (uint32_t)p.y);
    [self buttonEvent:ev button:MBT_NOTHING action:MA_MOVE];
}

- (void)scrollWheel:(NSEvent *)ev
{
    PTSession *s = self.session;
    if (!s || !s->term)
        return;

    CGFloat dy = ev.scrollingDeltaY, dx = ev.scrollingDeltaX;
    if (ev.hasPreciseScrollingDeltas) {
        /* Trackpad deltas are in points; convert to lines. */
        dy /= s->font_height;
        dx /= s->font_height;
    } else {
        dy *= SCROLL_INCREMENT_LINES / 3.0;
        dx *= SCROLL_INCREMENT_LINES / 3.0;
    }

    int x, y;
    [self cellForEvent:ev x:&x y:&y];
    NSEventModifierFlags mods = ev.modifierFlags;
    bool shift = mods & NSEventModifierFlagShift;
    bool ctrl = mods & NSEventModifierFlagControl;
    bool alt = [self metaForFlags:mods];

    /* Scrolling content up (dy > 0) shows older lines. */
    s->cumulative_vscroll -= dy;

    if (![self rawMouseMode:ev]) {
        int lines = (int)s->cumulative_vscroll;   /* rounds toward 0 */
        if (lines) {
            term_scroll(s->term, 0, lines);
            s->cumulative_vscroll -= lines;
        }
        return;
    }

    int events = (int)(s->cumulative_vscroll / SCROLL_INCREMENT_LINES);
    if (events) {
        s->cumulative_vscroll -= events * SCROLL_INCREMENT_LINES;
        Mouse_Button b = events > 0 ? MBT_WHEEL_DOWN : MBT_WHEEL_UP;
        for (int i = abs(events); i > 0; i--)
            term_mouse(s->term, b, translate_button(b), MA_CLICK,
                       x, y, shift, ctrl, alt);
    }
    s->cumulative_hscroll -= dx;
    events = (int)(s->cumulative_hscroll / SCROLL_INCREMENT_LINES);
    if (events) {
        s->cumulative_hscroll -= events * SCROLL_INCREMENT_LINES;
        Mouse_Button b = events > 0 ? MBT_WHEEL_RIGHT : MBT_WHEEL_LEFT;
        for (int i = abs(events); i > 0; i--)
            term_mouse(s->term, b, translate_button(b), MA_CLICK,
                       x, y, shift, ctrl, alt);
    }
}

/* --- Keyboard --- */

- (BOOL)performKeyEquivalent:(NSEvent *)ev
{
    PTSession *s = self.session;
    /*
     * If Command is acting as Meta, Command-keystrokes belong to the
     * terminal rather than the menus, while we have the focus.
     */
    if (s && s->command_meta && self.window.firstResponder == self &&
        (ev.modifierFlags & NSEventModifierFlagCommand)) {
        [self keyDown:ev];
        return YES;
    }
    return [super performKeyEquivalent:ev];
}

- (void)keyDown:(NSEvent *)ev
{
    PTSession *s = self.session;
    if (!s || !s->term)
        return;
    [s keyDown:ev];
}

/* --- NSTextInputClient, for text and input methods --- */

- (void)insertText:(id)string replacementRange:(NSRange)range
{
    PTSession *s = self.session;
    NSString *str = [string isKindOfClass:[NSAttributedString class]] ?
        [string string] : string;
    if (self.markedString) {
        self.markedString = nil;
        if (s && s->term)
            term_set_preedit_text(s->term, NULL);
    }
    if (!s || !s->term || !str.length)
        return;
    const char *utf8 = str.UTF8String;
    term_keyinput(s->term, CP_UTF8, utf8, (int)strlen(utf8));
    show_mouseptr(s, false);
}

- (void)doCommandBySelector:(SEL)selector
{
    /* Keys that mean editing commands are handled before we get
     * here; anything else the input system can't turn into text is
     * ignored. */
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)sel
     replacementRange:(NSRange)range
{
    PTSession *s = self.session;
    NSString *str = [string isKindOfClass:[NSAttributedString class]] ?
        [string string] : string;
    self.markedString = str.length ? str : nil;
    if (s && s->term) {
        if (str.length) {
            char *u = dupstr(str.UTF8String);
            term_set_preedit_text(s->term, u);
            sfree(u);
        } else {
            term_set_preedit_text(s->term, NULL);
        }
    }
}

- (void)unmarkText
{
    PTSession *s = self.session;
    self.markedString = nil;
    if (s && s->term)
        term_set_preedit_text(s->term, NULL);
}

- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange
{
    return self.markedString ? NSMakeRange(0, self.markedString.length) :
        NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText { return self.markedString != nil; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actual
{
    return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText
{
    return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actual
{
    PTSession *s = self.session;
    NSRect r = s ? s->cursor_rect : NSZeroRect;
    r = [self convertRect:r toView:nil];
    return [self.window convertRectToScreen:r];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    return NSNotFound;
}

@end

/* ----------------------------------------------------------------------
 * The session object: window management, menus and keyboard input.
 */

@implementation PTSession

- (void)dealloc
{
    /* Everything else was freed by delete_inst. */
}

- (void)layoutSubviews
{
    NSView *c = self.container;
    NSRect b = c.bounds;
    bool sb = conf_get_bool(conf, CONF_scrollbar);
    bool left = conf_get_bool(conf, CONF_scrollbar_on_left);
    CGFloat sbw = sb ? [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                                 scrollerStyle:NSScrollerStyleLegacy] : 0;
    NSRect termrect = b, sbrect = b;
    termrect.size.width -= sbw;
    sbrect.size.width = sbw;
    if (left)
        termrect.origin.x += sbw;
    else
        sbrect.origin.x = NSMaxX(b) - sbw;
    self.scroller.hidden = !sb;
    self.scroller.frame = sbrect;
    self.view.frame = termrect;
}

/* Called when the window changes size, to resize the terminal. */
- (void)viewSizeChanged
{
    if (!term || !font)
        return;
    NSSize sz = self.view.bounds.size;
    int w = (int)floor((sz.width - 2 * window_border) / font_width);
    int h = (int)floor((sz.height - 2 * window_border) / font_height);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (w != width || h != height) {
        width = w;
        height = h;
        term_size(term, h, w, conf_get_int(conf, CONF_savelines));
    }
    term_notify_window_size_pixels(term, (int)sz.width, (int)sz.height);
}

- (void)windowDidResize:(NSNotification *)n
{
    [self layoutSubviews];
    [self viewSizeChanged];
}

- (void)windowDidMove:(NSNotification *)n
{
    if (!term)
        return;
    NSScreen *screen = self.window.screen;
    if (!screen)
        return;
    NSRect sf = screen.frame, wf = self.window.frame;
    term_notify_window_pos(term, (int)(wf.origin.x - sf.origin.x),
                           (int)(NSMaxY(sf) - NSMaxY(wf)));
}

- (void)windowDidMiniaturize:(NSNotification *)n
{
    if (term)
        term_notify_minimised(term, true);
}

- (void)windowDidDeminiaturize:(NSNotification *)n
{
    if (term)
        term_notify_minimised(term, false);
}

- (void)windowDidBecomeKey:(NSNotification *)n
{
    if (!term)
        return;
    term_set_focus(term, true);
    term_update(term);
}

- (void)windowDidResignKey:(NSNotification *)n
{
    if (!term)
        return;
    term_set_focus(term, false);
    term_update(term);
}

static void warn_on_close_done(void *vctx, int result)
{
    PTSession *s = (__bridge PTSession *)vctx;
    if (result == 0) {
        s->closing = true;
        [s.window close];
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    if (closing || exited || !conf_get_bool(conf, CONF_warn_on_close))
        return YES;
    static const char *const buttons[] = { "Close", "Cancel" };
    char *title = dupcat(appname, " Exit Confirmation");
    void *box = macos_message_box(
        (__bridge void *)self.window, title,
        "Are you sure you want to close this session?", false,
        buttons, 2, warn_on_close_done, (__bridge void *)self);
    macos_frontend_register_dialog(&fe.seat, box);
    sfree(title);
    return NO;
}

- (void)windowWillClose:(NSNotification *)n
{
    closing = true;
    delete_inst(self);
    self.view.session = nil;
    self.window.delegate = nil;
    /* Let go of ourselves (and the window, which is still closing)
     * once we're back in the event loop. */
    PTSession *me = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [all_sessions removeObject:me];
        macos_session_closed();
    });
}

/* Is the session live, so that quitting would cut it off? */
- (bool)wantsQuitConfirmation
{
    return !exited && conf_get_bool(conf, CONF_warn_on_close);
}

/* --- Keyboard --- */

static int return_key(PTSession *s, char *output, bool *special)
{
    int end;
    if (s->term->cr_lf_return) {
        output[1] = '\015';
        output[2] = '\012';
        end = 3;
    } else {
        output[1] = '\015';
        end = 2;
        *special = true;
    }
    return end;
}

- (void)keyDown:(NSEvent *)ev
{
    PTTermView *v = self.view;

    /* While an input method is composing, it gets everything. */
    if (v.hasMarkedText) {
        [v interpretKeyEvents:@[ev]];
        return;
    }

    NSEventModifierFlags mods = ev.modifierFlags;
    bool shift = mods & NSEventModifierFlagShift;
    bool ctrl = mods & NSEventModifierFlagControl;
    bool cmd = mods & NSEventModifierFlagCommand;
    bool meta = [v metaForFlags:mods];
    unsigned short kc = ev.keyCode;
    NSString *ign = ev.charactersIgnoringModifiers;
    unichar basech = ign.length ? [ign characterAtIndex:0] : 0;

    /* Command keys that aren't Meta are menu shortcuts, not input. */
    if (cmd && !command_meta)
        return;

    char output[64];
    int start, end;
    bool special = false;
    output[0] = '\033';                /* Meta+things gives leading Escape */
    start = meta ? 0 : 1;
    end = 1;

    /* Shift-PgUp and Shift-PgDn don't even generate keystrokes. */
    if (kc == VK_PageUp && shift && ctrl) {
        term_scroll(term, 1, 0);
        return;
    }
    if (kc == VK_PageUp && shift) {
        term_scroll(term, 0, -height / 2);
        return;
    }
    if (kc == VK_PageUp && ctrl) {
        term_scroll(term, 0, -1);
        return;
    }
    if (kc == VK_PageDown && shift && ctrl) {
        term_scroll(term, -1, 0);
        return;
    }
    if (kc == VK_PageDown && shift) {
        term_scroll(term, 0, +height / 2);
        return;
    }
    if (kc == VK_PageDown && ctrl) {
        term_scroll(term, 0, +1);
        return;
    }

    /* Neither do Shift-Ins or Ctrl-Ins (if enabled). */
    if (kc == VK_Help && (shift || ctrl)) {
        int cfgval = conf_get_int(conf, CONF_ctrlshiftins);
        int clip = (cfgval == CLIPUI_IMPLICIT ? CLIP_LOCAL :
                    cfgval == CLIPUI_EXPLICIT ? CLIP_CLIPBOARD : CLIP_NULL);
        if (clip != CLIP_NULL) {
            if (shift)
                term_request_paste(term, clip);
            else
                term_request_copy(term, &clip, 1);
            return;
        }
    }

    /* Ctrl-Shift-C and Ctrl-Shift-V, if enabled. */
    if (ctrl && shift && (basech == 'C' || basech == 'c' ||
                          basech == 'V' || basech == 'v')) {
        int cfgval = conf_get_int(conf, CONF_ctrlshiftcv);
        int clip = (cfgval == CLIPUI_IMPLICIT ? CLIP_LOCAL :
                    cfgval == CLIPUI_EXPLICIT ? CLIP_CLIPBOARD : CLIP_NULL);
        if (clip != CLIP_NULL) {
            if (basech == 'V' || basech == 'v')
                term_request_paste(term, clip);
            else
                term_request_copy(term, &clip, 1);
            return;
        }
    }

    /* The numeric keypad. */
    char num_keypad_key = 0;
    bool numeric = false;
    switch (kc) {
      case VK_KeypadClear: num_keypad_key = 'G'; break;
      case VK_KeypadDivide: num_keypad_key = '/'; break;
      case VK_KeypadMultiply: num_keypad_key = '*'; break;
      case VK_KeypadMinus: num_keypad_key = '-'; break;
      case VK_KeypadPlus: num_keypad_key = '+'; break;
      case VK_KeypadEnter: num_keypad_key = '\r'; break;
      case VK_Keypad0: num_keypad_key = '0'; numeric = true; break;
      case VK_Keypad1: num_keypad_key = '1'; numeric = true; break;
      case VK_Keypad2: num_keypad_key = '2'; numeric = true; break;
      case VK_Keypad3: num_keypad_key = '3'; numeric = true; break;
      case VK_Keypad4: num_keypad_key = '4'; numeric = true; break;
      case VK_Keypad5: num_keypad_key = '5'; numeric = true; break;
      case VK_Keypad6: num_keypad_key = '6'; numeric = true; break;
      case VK_Keypad7: num_keypad_key = '7'; numeric = true; break;
      case VK_Keypad8: num_keypad_key = '8'; numeric = true; break;
      case VK_Keypad9: num_keypad_key = '9'; numeric = true; break;
      case VK_KeypadDecimal: num_keypad_key = '.'; numeric = true; break;
    }
    if (num_keypad_key) {
        bool nethack_mode = conf_get_bool(conf, CONF_nethack_keypad);
        bool app_keypad_mode = (term->app_keypad_keys &&
                                !conf_get_bool(conf, CONF_no_applic_k));
        if ((app_keypad_mode &&
             (numeric || term->funky_type != FUNKY_XTERM)) ||
            (nethack_mode && num_keypad_key >= '1' &&
             num_keypad_key <= '9')) {
            end = 1 + format_numeric_keypad_key(output + 1, term,
                                                num_keypad_key, shift, ctrl);
            if (end == 1 && num_keypad_key == '\r')
                end = return_key(self, output, &special);
            goto done;
        }
        if (num_keypad_key == '\r') {
            end = return_key(self, output, &special);
            goto done;
        }
        if (!numeric && num_keypad_key != '/' && num_keypad_key != '*' &&
            num_keypad_key != '-' && num_keypad_key != '+')
            return;                    /* Clear, outside keypad modes */
        /* Otherwise it's just the character on the key. */
    }

    {
        int fkey = 0;
        switch (kc) {
          case VK_F1: fkey = 1; break;
          case VK_F2: fkey = 2; break;
          case VK_F3: fkey = 3; break;
          case VK_F4: fkey = 4; break;
          case VK_F5: fkey = 5; break;
          case VK_F6: fkey = 6; break;
          case VK_F7: fkey = 7; break;
          case VK_F8: fkey = 8; break;
          case VK_F9: fkey = 9; break;
          case VK_F10: fkey = 10; break;
          case VK_F11: fkey = 11; break;
          case VK_F12: fkey = 12; break;
          case VK_F13: fkey = 13; break;
          case VK_F14: fkey = 14; break;
          case VK_F15: fkey = 15; break;
          case VK_F16: fkey = 16; break;
          case VK_F17: fkey = 17; break;
          case VK_F18: fkey = 18; break;
          case VK_F19: fkey = 19; break;
          case VK_F20: fkey = 20; break;
        }
        if (fkey) {
            bool consumed_meta = false;
            end = 1 + format_function_key(output + 1, term, fkey, shift,
                                          ctrl, meta, &consumed_meta);
            if (consumed_meta)
                start = 1;
            goto done;
        }
    }

    {
        int sk = -1;
        switch (kc) {
          case VK_Home: sk = SKK_HOME; break;
          case VK_Help: sk = SKK_INSERT; break;
          case VK_ForwardDelete: sk = SKK_DELETE; break;
          case VK_End: sk = SKK_END; break;
          case VK_PageUp: sk = SKK_PGUP; break;
          case VK_PageDown: sk = SKK_PGDN; break;
        }
        if (sk >= 0) {
            /* These keys don't generate terminal input with Ctrl */
            if (ctrl)
                return;
            bool consumed_meta = false;
            end = 1 + format_small_keypad_key(output + 1, term,
                                              (SmallKeypadKey)sk, shift,
                                              ctrl, meta, &consumed_meta);
            if (consumed_meta)
                start = 1;
            goto done;
        }
    }

    {
        int xkey = 0;
        switch (kc) {
          case VK_UpArrow: xkey = 'A'; break;
          case VK_DownArrow: xkey = 'B'; break;
          case VK_RightArrow: xkey = 'C'; break;
          case VK_LeftArrow: xkey = 'D'; break;
        }
        if (xkey) {
            bool consumed_meta = false;
            end = 1 + format_arrow_key(output + 1, term, xkey, shift, ctrl,
                                       meta, &consumed_meta);
            if (consumed_meta)
                start = 1;
            goto done;
        }
    }

    if (kc == VK_Return) {
        end = return_key(self, output, &special);
        goto done;
    }

    if (kc == VK_Delete) {
        bool bksp_is_delete = conf_get_bool(conf, CONF_bksp_is_delete);
        if (shift)
            bksp_is_delete = !bksp_is_delete;  /* do the opposite */
        output[1] = bksp_is_delete ? '\x7F' : '\x08';
        end = 2;
        special = true;
        goto done;
    }

    if (kc == VK_Tab) {
        if (shift)
            end = 1 + sprintf(output + 1, "\033[Z");
        else {
            output[1] = '\t';
            end = 2;
        }
        goto done;
    }

    if (kc == VK_Escape) {
        output[1] = '\033';
        end = 2;
        goto done;
    }

    if (ctrl) {
        /*
         * Control characters. These translations are in line with
         * X11 policy, as in the GTK front end.
         */
        int c = basech;
        if (kc == VK_Space)
            c = ' ';
        if (c == ' ' && shift) {
            /* Ctrl-Shift-Space is 160 (ISO8859 nonbreaking space) */
            wchar_t nbsp = 0xA0;
            if (meta)
                term_keyinput(term, -1, "\033", 1);
            term_keyinputw(term, &nbsp, 1);
            show_mouseptr(self, false);
            return;
        }
        int new = -1;
        if (c >= '3' && c <= '7')
            new = c + '\x1B' - '3';    /* ^3,...,^7 map to 0x1B,...,0x1F */
        else if (c == '2' || c == ' ' || c == '@')
            new = 0;                   /* ^2, ^Space, ^@ are all ^@ */
        else if (c == '8')
            new = 0x7F;                /* ^8 is DEL */
        else if (c == '/')
            new = 0x1F;                /* ^/ is the same as ^_ */
        else if (c >= 0x40 && c < 0x7F)
            new = c & 0x1F;            /* everything near the alphabetics */
        if (new >= 0) {
            output[1] = new;
            end = 2;
            if (new == 0)
                special = false;
            goto done;
        }
        /* Anything else, e.g. '0', is unchanged; fall through. */
    }

    if (meta) {
        /*
         * Meta+key sends Escape followed by the key's own character
         * (ignoring the modifier being used as Meta).
         */
        NSString *chars = ign;
        if (!cmd && (mods & NSEventModifierFlagOption) && !shift) {
            chars = ign;
        }
        if (!chars.length)
            return;
        const char *utf8 = chars.UTF8String;
        term_keyinput(term, -1, "\033", 1);
        term_keyinput(term, CP_UTF8, utf8, (int)strlen(utf8));
        show_mouseptr(self, false);
        return;
    }

    /* Ordinary text, dead keys and input methods. */
    [v interpretKeyEvents:@[ev]];
    return;

  done:
    if (end - start > 0) {
        if (special) {
            /* For special control characters, the character set
             * should never matter. */
            output[end] = '\0';        /* NUL-terminate */
            term_keyinput(term, -1, output + start, -2);
        } else {
            term_keyinput(term, -1, output + start, end - start);
        }
        show_mouseptr(self, false);
    }
}

/* --- Menu actions (reached through the responder chain) --- */

- (void)copy:(id)sender
{
    int clip = CLIP_CLIPBOARD;
    if (term)
        term_request_copy(term, &clip, 1);
}

- (void)paste:(id)sender
{
    if (term)
        term_request_paste(term, CLIP_CLIPBOARD);
}

- (void)copyAll:(id)sender
{
    int clip = CLIP_CLIPBOARD;
    if (term)
        term_copyall(term, &clip, 1);
}

- (void)clearScrollback:(id)sender
{
    if (term)
        term_clrsb(term);
}

- (void)resetTerminal:(id)sender
{
    if (!term)
        return;
    term_pwron(term, true);
    if (ldisc)
        ldisc_echoedit_update(ldisc);
}

- (void)duplicateSession:(id)sender
{
    if (conf)
        macos_open_session(conf_copy(conf));
}

- (void)restartSession:(id)sender
{
    if (!backend && term) {
        logevent(logctx, "----- Session restarted -----");
        term_pwron(term, false);
        exited = false;
        start_backend(self);
        if (ldisc)
            ldisc_echoedit_update(ldisc);
    }
}

- (void)showEventLog:(id)sender
{
    showeventlog(eventlogstuff, (__bridge void *)self.window);
}

- (void)specialCommand:(id)sender
{
    PTSpecial *sp = [sender representedObject];
    if (backend && sp)
        backend_special(backend, sp.code, sp.arg);
}

- (void)fillSpecialsMenu:(NSMenu *)menu
{
    [menu removeAllItems];
    const SessionSpecial *specials = backend ?
        backend_get_specials(backend) : NULL;
    if (!specials) {
        NSMenuItem *it = [menu addItemWithTitle:@"(None)" action:NULL
                                  keyEquivalent:@""];
        it.enabled = NO;
        return;
    }
    NSMenu *cur = menu, *saved = nil;
    int nesting = 1;
    for (int i = 0; nesting > 0; i++) {
        switch (specials[i].code) {
          case SS_SUBMENU: {
            NSMenuItem *it = [cur addItemWithTitle:ns(specials[i].name)
                                            action:NULL keyEquivalent:@""];
            NSMenu *sub = [[NSMenu alloc] initWithTitle:ns(specials[i].name)];
            it.submenu = sub;
            saved = cur;
            cur = sub;
            nesting++;
            break;
          }
          case SS_EXITMENU:
            nesting--;
            if (nesting) {
                cur = saved;
                saved = nil;
            }
            break;
          case SS_SEP:
            [cur addItem:[NSMenuItem separatorItem]];
            break;
          default: {
            NSMenuItem *it = [cur addItemWithTitle:ns(specials[i].name)
                                            action:@selector(specialCommand:)
                                     keyEquivalent:@""];
            PTSpecial *sp = [[PTSpecial alloc] init];
            sp.code = specials[i].code;
            sp.arg = specials[i].arg;
            it.representedObject = sp;
            it.target = self;
            break;
          }
        }
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    /* Only used for the context menu's Special Commands submenu. */
    [self fillSpecialsMenu:menu];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = item.action;
    if (a == @selector(restartSession:))
        return !backend && term && !closing;
    if (a == @selector(duplicateSession:))
        return conf != NULL && conf_launchable(conf);
    if (a == @selector(changeSettings:))
        return !reconfiguring && term != NULL;
    if (a == @selector(specialCommand:))
        return backend != NULL;
    return term != NULL;
}

/* Bigger and smaller fonts (Command-plus and Command-minus) */
- (void)changeFontSize:(int)increment
{
    FontSpec *fs = conf_get_fontspec(conf, CONF_font);
    CGFloat size;
    CTFontRef f = font_from_name(fs->name, &size);
    NSString *name = f ? (NSString *)CFBridgingRelease(
        CTFontCopyPostScriptName(f)) : @"Menlo-Regular";
    if (f)
        CFRelease(f);
    CGFloat newsize = size + increment;
    if (newsize < 6 || newsize > 72)
        return;
    char *newname = dupprintf("%s %g", name.UTF8String, (double)newsize);
    FontSpec *nfs = fontspec_new(newname);
    sfree(newname);
    conf_set_fontspec(conf, CONF_font, nfs);
    fontspec_free(nfs);

    char *err = setup_fonts_ucs(self);
    sfree(err);
    set_geom_hints(self);
    resize_window_to_term(self, width, height);
    [self viewSizeChanged];
    draw_backing_rect(self);
    term_invalidate(term);
}

- (void)biggerFont:(id)sender
{
    [self changeFontSize:+1];
}

- (void)smallerFont:(id)sender
{
    [self changeFontSize:-1];
}

struct reconfig_ctx {
    void *session;                     /* retained PTSession */
    Conf *newconf;
};

static void after_change_settings(void *vctx, int retval)
{
    struct reconfig_ctx *ctx = (struct reconfig_ctx *)vctx;
    PTSession *s = (PTSession *)CFBridgingRelease(ctx->session);
    Conf *newconf = ctx->newconf;
    sfree(ctx);

    s->reconfiguring = false;
    if (retval <= 0 || !s->term || s->closing) {
        conf_free(newconf);
        return;
    }

    Conf *oldconf = s->conf;
    s->conf = newconf;

    /* Pass new config data to the logging module */
    log_reconfig(s->logctx, s->conf);
    /* Flush the line discipline's edit buffer in the case where
     * local editing has just been disabled. */
    if (s->ldisc) {
        ldisc_configure(s->ldisc, s->conf);
        ldisc_echoedit_update(s->ldisc);
    }
    /* Pass new config data to the terminal */
    term_reconfig(s->term, s->conf);
    setup_clipboards(s);
    /* Pass new config data to the back end */
    if (s->backend)
        backend_reconfig(s->backend, s->conf);

    cache_conf_values(s);

    bool need_size = false;

    if (conf_get_bool(oldconf, CONF_scrollbar) !=
        conf_get_bool(newconf, CONF_scrollbar) ||
        conf_get_bool(oldconf, CONF_scrollbar_on_left) !=
        conf_get_bool(newconf, CONF_scrollbar_on_left)) {
        [s layoutSubviews];
        need_size = true;
    }

    if (strcmp(conf_get_fontspec(oldconf, CONF_font)->name,
               conf_get_fontspec(newconf, CONF_font)->name) ||
        strcmp(conf_get_str(oldconf, CONF_line_codepage),
               conf_get_str(newconf, CONF_line_codepage)) ||
        conf_get_bool(oldconf, CONF_utf8_override) !=
        conf_get_bool(newconf, CONF_utf8_override) ||
        conf_get_int(oldconf, CONF_vtmode) !=
        conf_get_int(newconf, CONF_vtmode) ||
        conf_get_bool(oldconf, CONF_shadowbold) !=
        conf_get_bool(newconf, CONF_shadowbold)) {
        char *errmsg = setup_fonts_ucs(s);
        if (errmsg) {
            static const char *const ok[] = { "OK" };
            char *msg = dupprintf("Could not change fonts in terminal "
                                  "window: %s", errmsg);
            macos_message_box((__bridge void *)s.window, "Font setup error",
                              msg, false, ok, 1, NULL, NULL);
            sfree(msg);
            sfree(errmsg);
        } else {
            need_size = true;
        }
    }

    set_geom_hints(s);
    s.window.styleMask = (conf_get_int(s->conf, CONF_resize_action) ==
                          RESIZE_DISABLED) ?
        (s.window.styleMask & ~NSWindowStyleMaskResizable) :
        (s.window.styleMask | NSWindowStyleMaskResizable);

    if (conf_get_int(oldconf, CONF_width) !=
        conf_get_int(newconf, CONF_width) ||
        conf_get_int(oldconf, CONF_height) !=
        conf_get_int(newconf, CONF_height) ||
        conf_get_int(oldconf, CONF_window_border) !=
        conf_get_int(newconf, CONF_window_border) || need_size) {
        resize_window_to_term(s, conf_get_int(newconf, CONF_width),
                              conf_get_int(newconf, CONF_height));
        [s layoutSubviews];
        [s viewSizeChanged];
    } else if (conf_get_int(oldconf, CONF_savelines) !=
               conf_get_int(newconf, CONF_savelines)) {
        term_size(s->term, s->term->rows, s->term->cols,
                  conf_get_int(newconf, CONF_savelines));
    }

    draw_backing_rect(s);
    term_invalidate(s->term);
    conf_free(oldconf);
}

- (void)changeSettings:(id)sender
{
    if (reconfiguring || !term)
        return;
    reconfiguring = true;

    struct reconfig_ctx *ctx = snew(struct reconfig_ctx);
    ctx->session = (void *)CFBridgingRetain(self);
    ctx->newconf = conf_copy(conf);
    term_pre_reconfig(term, ctx->newconf);

    char *title = dupcat(appname, " Reconfiguration");
    macos_config_box(title, ctx->newconf, true,
                     backend ? backend_cfg_info(backend) : 0,
                     (__bridge void *)self.window,
                     after_change_settings, ctx);
    sfree(title);
}

- (void)scrollerMoved:(NSScroller *)sc
{
    if (!term)
        return;
    switch (sc.hitPart) {
      case NSScrollerDecrementPage:
        term_scroll(term, 0, -height);
        break;
      case NSScrollerIncrementPage:
        term_scroll(term, 0, +height);
        break;
      case NSScrollerKnob:
      case NSScrollerKnobSlot: {
        int total = term->tempsblines + term->rows;
        int page = term->rows;
        if (total > page)
            term_scroll(term, 1, (int)lround(sc.doubleValue *
                                             (total - page)));
        break;
      }
      default:
        break;
    }
}

- (NSMenu *)contextMenu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *it;
#define ITEM(title, sel, tgt) do {                                      \
        it = [m addItemWithTitle:title action:sel keyEquivalent:@""];   \
        it.target = tgt;                                                \
    } while (0)
    id app = [NSApp delegate];
    ITEM(@"New Session...", @selector(newSession:), app);
    ITEM(@"Restart Session", @selector(restartSession:), self);
    ITEM(@"Duplicate Session", @selector(duplicateSession:), self);
    it = [m addItemWithTitle:@"Saved Sessions" action:NULL keyEquivalent:@""];
    it.submenu = [[NSMenu alloc] initWithTitle:@"Saved Sessions"];
    it.submenu.delegate = app;
    [m addItem:[NSMenuItem separatorItem]];
    ITEM(@"Change Settings...", @selector(changeSettings:), self);
    [m addItem:[NSMenuItem separatorItem]];
    ITEM(@"Event Log", @selector(showEventLog:), self);
    if (backend && backend_get_specials(backend)) {
        it = [m addItemWithTitle:@"Special Commands" action:NULL
                   keyEquivalent:@""];
        it.submenu = [[NSMenu alloc] initWithTitle:@"Special Commands"];
        [self fillSpecialsMenu:it.submenu];
    }
    [m addItem:[NSMenuItem separatorItem]];
    ITEM(@"Clear Scrollback", @selector(clearScrollback:), self);
    ITEM(@"Reset Terminal", @selector(resetTerminal:), self);
    [m addItem:[NSMenuItem separatorItem]];
    ITEM(@"Copy", @selector(copy:), self);
    ITEM(@"Paste", @selector(paste:), self);
    ITEM(@"Copy All", @selector(copyAll:), self);
    [m addItem:[NSMenuItem separatorItem]];
    ITEM([@"About " stringByAppendingString:ns(appname)],
         @selector(orderFrontStandardAboutPanel:), app);
#undef ITEM
    return m;
}

@end

/* ----------------------------------------------------------------------
 * Creating a session window.
 */

bool macos_any_session_wants_quit_confirmation(void)
{
    for (PTSession *s in all_sessions)
        if ([s wantsQuitConfirmation])
            return true;
    return false;
}

MacFrontend *macos_frontend_new(Conf *conf)
{
    if (!all_sessions)
        all_sessions = [NSMutableSet set];

    prepare_session(conf);

    PTSession *s = [[PTSession alloc] init];
    s->fe.session = (__bridge void *)s;
    s->fe.seat.vt = &mac_seat_vt;
    s->fe.termwin.vt = &mac_termwin_vt;
    s->fe.logpolicy.vt = &mac_logpolicy_vt;
    s->conf = conf;
    s->busy_status = BUSY_NOT;
    s->dialogs = [NSMutableArray array];
    s->backing_scale = 1;

    cache_conf_values(s);
    {
        char *err = setup_fonts_ucs(s);
        if (err) {
            static const char *const ok[] = { "OK" };
            macos_message_box(NULL, "Error creating session window", err,
                              true, ok, 1, NULL, NULL);
            sfree(err);
            conf_free(conf);
            s->conf = NULL;
            return NULL;
        }
    }

    s->width = conf_get_int(conf, CONF_width);
    s->height = conf_get_int(conf, CONF_height);

    NSSize csize = content_size_for(s, s->width, s->height);
    NSWindowStyleMask style = (NSWindowStyleMaskTitled |
                               NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable);
    if (conf_get_int(conf, CONF_resize_action) != RESIZE_DISABLED)
        style |= NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc]
                        initWithContentRect:NSMakeRect(0, 0, csize.width,
                                                       csize.height)
                                  styleMask:style
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
    win.releasedWhenClosed = NO;
    win.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    win.title = ns(appname);
    s.window = win;

    NSView *container = [[NSView alloc]
                            initWithFrame:NSMakeRect(0, 0, csize.width,
                                                     csize.height)];
    s.container = container;
    win.contentView = container;

    NSScroller *sc = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0, 15, 100)];
    sc.scrollerStyle = NSScrollerStyleLegacy;
    sc.controlSize = NSControlSizeRegular;
    sc.enabled = NO;
    sc.target = s;
    sc.action = @selector(scrollerMoved:);
    s.scroller = sc;
    [container addSubview:sc];

    PTTermView *v = [[PTTermView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    v.session = s;
    s.view = v;
    [container addSubview:v];

    set_geom_hints(s);
    [s layoutSubviews];
    win.delegate = s;
    win.initialFirstResponder = v;

    [all_sessions addObject:s];

    s->eventlogstuff = eventlogstuff_new();

    s->term = term_init(conf, &s->ucsdata, &s->fe.termwin);
    setup_clipboards(s);
    s->logctx = log_init(&s->fe.logpolicy, conf);
    term_provide_logctx(s->term, s->logctx);
    term_size(s->term, s->height, s->width, conf_get_int(conf, CONF_savelines));

    setup_backing(s);

    /* Cascade new windows from the frontmost one. */
    static NSPoint cascade;
    if (NSEqualPoints(cascade, NSZeroPoint)) {
        [win center];
        cascade = NSMakePoint(NSMinX(win.frame), NSMaxY(win.frame));
    }
    cascade = [win cascadeTopLeftFromPoint:cascade];
    [win makeKeyAndOrderFront:nil];
    [win makeFirstResponder:v];

    /* The window manager may have adjusted the size. */
    [s layoutSubviews];
    [s viewSizeChanged];

    s->exited = false;
    start_backend(s);
    if (s->ldisc) /* early backend failure might make this NULL already */
        ldisc_echoedit_update(s->ldisc); /* cause ldisc to notice changes */

    return &s->fe;
}
