/*
 * dialog.m: dialog boxes for the native macOS front end.
 *
 * This implements the platform half of PuTTY's portable dialog
 * description language (dialog.h) using AppKit controls, plus the
 * configuration box built from it, message boxes, the various
 * security prompts, the About box and the Event Log.
 *
 * Layout is done by hand, in flipped views, following the column
 * structure in each controlset in much the same way as the GTK and
 * Windows front ends do.
 */

#import <Cocoa/Cocoa.h>

#include <assert.h>
#include <limits.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"
#include "ssh.h"
#include "licence.h"
#include "macputty.h"

#define GAP 6                          /* between controls */
#define MARGIN 14                      /* around the edges of a window */
#define MAXCOLS 16

static NSString *ns(const char *s)
{
    NSString *ret = s ? [NSString stringWithUTF8String:s] : nil;
    if (!ret && s)
        ret = [[NSString alloc] initWithBytes:s length:strlen(s)
                                     encoding:NSISOLatin1StringEncoding];
    return ret ? ret : @"";
}

static char *dupns(NSString *s)
{
    const char *u = s.UTF8String;
    return dupstr(u ? u : "");
}

@interface PTFlipView : NSView
@end
@implementation PTFlipView
- (BOOL)isFlipped { return YES; }
@end

/* ----------------------------------------------------------------------
 * Data structures.
 */

struct dlgparam {
    void *dlg;                         /* the PTDialog, not retained */
};

@class PTDialog;

/* One of these for each control in a dialog. */
@interface PTUCtrl : NSObject <NSTextFieldDelegate, NSComboBoxDelegate,
                               NSTableViewDataSource, NSTableViewDelegate>
@property (weak) PTDialog *dialog;
@property (assign) dlgcontrol *ctrl;
@property (strong) NSView *toplevel;
@property (strong) NSTextField *label;
@property (strong) NSTextField *entry;   /* edit box, file or font selector */
@property (strong) NSComboBox *combo;    /* edit box with a list */
@property (strong) NSButton *button;     /* checkbox or push button */
@property (strong) NSArray<NSButton *> *radios;
@property (strong) NSPopUpButton *popup; /* drop-down list */
@property (strong) NSTableView *table;   /* list box */
@property (strong) NSTextField *text;    /* static text */
@property (strong) NSMutableArray<NSString *> *items;
@property (strong) NSMutableArray<NSNumber *> *ids;
@property (copy) NSString *textvalue;    /* for button-only file selectors */
@property int panel;                     /* -1 if always visible */
@property bool suppress;                 /* ignore control notifications */
- (void)send:(int)event;
@end

@interface PTDialogWindow : NSWindow
@end

@interface PTDialog : NSObject <NSWindowDelegate, NSOutlineViewDataSource,
                                NSOutlineViewDelegate>
{
@public
    struct dlgparam dp;
}
@property (strong) NSWindow *window;
@property (strong) NSWindow *sheetParent;   /* if we're a sheet */
@property (assign) struct controlbox *ctrlbox;
@property bool ownsBox;
@property (assign) void *data;
@property (strong) NSMutableDictionary<NSValue *, PTUCtrl *> *byctrl;
@property (strong) NSMutableDictionary<NSValue *, PTUCtrl *> *byview;
@property (strong) NSMutableArray<PTUCtrl *> *uctrls;
@property (assign) dlgcontrol *currfocus, *lastfocus;
@property int retval;
@property (assign) macos_dialog_done_fn after;
@property (assign) void *afterctx;
@property bool ended;
@property int colr, colg, colb;
@property bool colok;
@property (copy) void (^onFinish)(void);
@property (copy) NSString *copyText;

/* Config box only */
@property (strong) NSOutlineView *tree;
@property (strong) NSMutableArray *treeRoots;
@property (strong) NSMutableArray<NSView *> *panels;
@property int currpanel;

- (void)focusChanged:(NSResponder *)r;
- (void)endWithValue:(int)value;
- (void)abandon;
- (void)finish;
- (void)showPanel:(int)which;
@end

@interface PTTreeNode : NSObject
@property (copy) NSString *title;
@property (strong) NSMutableArray<PTTreeNode *> *children;
@property int panel;
@end
@implementation PTTreeNode
@end

static NSMutableSet *open_dialogs;

static inline PTDialog *DLG(dlgparam *dp)
{
    return (__bridge PTDialog *)dp->dlg;
}

static NSValue *key_for(const void *p)
{
    return [NSValue valueWithPointer:p];
}

static PTUCtrl *UC(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = DLG(dp).byctrl[key_for(ctrl)];
    assert(uc);
    return uc;
}

/* ----------------------------------------------------------------------
 * Control behaviour.
 */

@implementation PTUCtrl

- (void)send:(int)event
{
    PTDialog *d = self.dialog;
    dlgcontrol *ctrl = self.ctrl;
    if (!d || d.ended || !ctrl || !ctrl->handler)
        return;
    ctrl->handler(ctrl, &d->dp, d.data, event);
}

- (void)checkboxChanged:(id)sender
{
    [self send:EVENT_VALCHANGE];
}

- (void)radioChanged:(id)sender
{
    for (NSButton *b in self.radios)
        b.state = (b == sender) ? NSControlStateValueOn :
            NSControlStateValueOff;
    [self send:EVENT_VALCHANGE];
}

- (void)buttonPressed:(id)sender
{
    [self send:EVENT_ACTION];
}

- (void)popupChanged:(id)sender
{
    if (!self.suppress)
        [self send:EVENT_SELCHANGE];
}

- (void)controlTextDidChange:(NSNotification *)n
{
    if (!self.suppress)
        [self send:EVENT_VALCHANGE];
}

- (void)controlTextDidEndEditing:(NSNotification *)n
{
    /* Losing the focus gives the handler a chance to tidy up what
     * the user typed, as in the other front ends. */
    [self send:EVENT_REFRESH];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)n
{
    if (self.suppress)
        return;
    /* The text in the box isn't updated until after this. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self send:EVENT_VALCHANGE];
    });
}

/* List boxes */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return self.items.count;
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)self.items.count)
        return @"";
    NSString *s = self.items[row];
    NSInteger ncols = tv.tableColumns.count;
    if (ncols <= 1)
        return s;
    NSInteger which = [tv.tableColumns indexOfObjectIdenticalTo:col];
    NSArray *parts = [s componentsSeparatedByString:@"\t"];
    if (which < 0 || which >= (NSInteger)parts.count)
        return @"";
    if (which == ncols - 1 && (NSInteger)parts.count > ncols) {
        /* Anything beyond the last column goes in the last column. */
        return [[parts subarrayWithRange:NSMakeRange(which,
                                                     parts.count - which)]
                   componentsJoinedByString:@" "];
    }
    return parts[which];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    if (!self.suppress)
        [self send:EVENT_SELCHANGE];
}

- (void)listDoubleClicked:(id)sender
{
    if (self.table.clickedRow >= 0)
        [self send:EVENT_ACTION];
}

- (void)dragMove:(int)direction
{
    NSInteger i = self.table.selectedRow;
    NSInteger j = i + direction;
    if (i < 0 || j < 0 || j >= (NSInteger)self.items.count) {
        NSBeep();
        return;
    }
    [self.items exchangeObjectAtIndex:i withObjectAtIndex:j];
    [self.ids exchangeObjectAtIndex:i withObjectAtIndex:j];
    self.suppress = true;
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:j]
            byExtendingSelection:NO];
    [self.table scrollRowToVisible:j];
    self.suppress = false;
    [self send:EVENT_VALCHANGE];
}

- (void)dragUp:(id)sender
{
    [self dragMove:-1];
}

- (void)dragDown:(id)sender
{
    [self dragMove:+1];
}

/* File and font selectors */

- (void)fileBrowse:(id)sender
{
    PTDialog *d = self.dialog;
    dlgcontrol *ctrl = self.ctrl;
    if (!d || d.ended)
        return;

    NSSavePanel *panel;
    if (ctrl->fileselect.for_writing) {
        panel = [NSSavePanel savePanel];
    } else {
        NSOpenPanel *op = [NSOpenPanel openPanel];
        op.canChooseFiles = YES;
        op.canChooseDirectories = NO;
        op.allowsMultipleSelection = NO;
        panel = op;
    }
    if (ctrl->fileselect.title)
        panel.message = ns(ctrl->fileselect.title);
    panel.showsHiddenFiles = YES;
    if (self.entry && self.entry.stringValue.length) {
        NSString *cur = self.entry.stringValue.stringByExpandingTildeInPath;
        panel.directoryURL = [NSURL fileURLWithPath:
                                  cur.stringByDeletingLastPathComponent];
        if (ctrl->fileselect.for_writing)
            panel.nameFieldStringValue = cur.lastPathComponent;
    }

    [panel beginSheetModalForWindow:d.window
                  completionHandler:^(NSModalResponse resp) {
        if (resp != NSModalResponseOK || !panel.URL || d.ended)
            return;
        NSString *path = panel.URL.path;
        if (self.entry) {
            self.entry.stringValue = path;
            [self send:EVENT_VALCHANGE];
        } else {
            self.textvalue = path;
            [self send:EVENT_ACTION];
            self.textvalue = nil;
        }
    }];
}

- (void)fontChange:(id)sender
{
    PTDialog *d = self.dialog;
    if (!d || d.ended)
        return;

    /* Work out the current family and size. */
    NSString *cur = self.entry.stringValue;
    if ([cur hasPrefix:@"client:"])
        cur = [cur substringFromIndex:7];
    NSString *family = @"Menlo";
    double size = 12;
    NSRange r = [cur rangeOfString:@" " options:NSBackwardsSearch];
    if (r.location != NSNotFound) {
        double sz = [cur substringFromIndex:r.location + 1].doubleValue;
        if (sz > 0) {
            size = sz;
            cur = [cur substringToIndex:r.location];
        }
    }
    if (cur.length) {
        NSFont *f = [NSFont fontWithName:cur size:size];
        family = f ? f.familyName : cur;
    }

    /* Monospaced families, which is what a terminal wants. */
    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSMutableSet *fams = [NSMutableSet set];
    for (NSString *name in [fm availableFontNamesWithTraits:
                                   NSFixedPitchFontMask]) {
        NSFont *f = [NSFont fontWithName:name size:12];
        if (f.familyName && ![f.familyName hasPrefix:@"."])
            [fams addObject:f.familyName];
    }
    [fams addObject:family];
    NSArray *sorted = [fams.allObjects sortedArrayUsingSelector:
                           @selector(localizedCaseInsensitiveCompare:)];

    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)];
    NSPopUpButton *pop = [[NSPopUpButton alloc]
                             initWithFrame:NSMakeRect(0, 28, 320, 26)
                                 pullsDown:NO];
    [pop addItemsWithTitles:sorted];
    [pop selectItemWithTitle:family];
    [acc addSubview:pop];
    NSTextField *lab = [NSTextField labelWithString:@"Size (points):"];
    lab.frame = NSMakeRect(0, 2, 110, 20);
    [acc addSubview:lab];
    NSTextField *sizef = [[NSTextField alloc]
                             initWithFrame:NSMakeRect(115, 0, 60, 22)];
    sizef.stringValue = [NSString stringWithFormat:@"%g", size];
    [acc addSubview:sizef];

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Select a font";
    a.informativeText = @"Choose the font for the terminal window.";
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:@"Cancel"];
    a.accessoryView = acc;
    [a beginSheetModalForWindow:d.window
              completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn || d.ended)
            return;
        double sz = sizef.doubleValue;
        if (sz < 4 || sz > 400)
            sz = size;
        self.entry.stringValue = [NSString stringWithFormat:@"%@ %g",
                                  pop.titleOfSelectedItem, sz];
        [self send:EVENT_VALCHANGE];
    }];
}

@end

/* ----------------------------------------------------------------------
 * Dialog windows.
 */

@implementation PTDialogWindow

- (BOOL)makeFirstResponder:(NSResponder *)r
{
    BOOL ok = [super makeFirstResponder:r];
    if (ok && [self.delegate isKindOfClass:[PTDialog class]])
        [(PTDialog *)self.delegate focusChanged:self.firstResponder];
    return ok;
}

@end

@implementation PTDialog

- (instancetype)init
{
    if ((self = [super init])) {
        dp.dlg = (__bridge void *)self;
        _byctrl = [NSMutableDictionary dictionary];
        _byview = [NSMutableDictionary dictionary];
        _uctrls = [NSMutableArray array];
        _currpanel = -1;
        if (!open_dialogs)
            open_dialogs = [NSMutableSet set];
        [open_dialogs addObject:self];
    }
    return self;
}

- (void)registerView:(NSView *)v forUC:(PTUCtrl *)uc
{
    if (v)
        self.byview[[NSValue valueWithNonretainedObject:v]] = uc;
}

- (void)focusChanged:(NSResponder *)r
{
    /* The field editor stands in for the text field being edited. */
    if ([r isKindOfClass:[NSText class]] && ((NSText *)r).isFieldEditor &&
        [(id)((NSText *)r).delegate isKindOfClass:[NSView class]])
        r = (NSResponder *)((NSText *)r).delegate;

    PTUCtrl *uc = nil;
    if ([r isKindOfClass:[NSView class]]) {
        for (NSView *v = (NSView *)r; v && !uc; v = v.superview)
            uc = self.byview[[NSValue valueWithNonretainedObject:v]];
    }
    dlgcontrol *focus = uc ? uc.ctrl : NULL;
    if (focus != self.currfocus) {
        self.lastfocus = self.currfocus;
        self.currfocus = focus;
    }
}

- (BOOL)windowShouldClose:(NSWindow *)w
{
    [self endWithValue:0];
    return NO;
}

- (void)endWithValue:(int)value
{
    if (self.ended)
        return;
    self.ended = true;
    self.retval = value;
    if (!self.sheetParent)
        [self.window orderOut:nil];
    /* Tidy up once whatever handler called us has returned. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finish];
    });
}

/* Close without telling anyone (because they've gone away). */
- (void)abandon
{
    self.onFinish = nil;
    self.after = NULL;
    self.data = NULL;
    [self endWithValue:0];
}

- (void)finish
{
    NSWindow *w = self.window;
    w.delegate = nil;
    if (self.sheetParent)
        [self.sheetParent endSheet:w];
    [w close];

    for (PTUCtrl *uc in self.uctrls) {
        uc.table.dataSource = nil;
        uc.table.delegate = nil;
        uc.entry.delegate = nil;
        uc.combo.delegate = nil;
        uc.ctrl = NULL;
    }
    self.tree.dataSource = nil;
    self.tree.delegate = nil;

    if (self.ownsBox && self.ctrlbox)
        ctrl_free_box(self.ctrlbox);
    self.ctrlbox = NULL;

    void (^onFinish)(void) = self.onFinish;
    self.onFinish = nil;
    if (onFinish)
        onFinish();
    if (self.after)
        self.after(self.afterctx, self.retval);

    [open_dialogs removeObject:self];
}

- (void)copy:(id)sender
{
    if (self.copyText.length) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:self.copyText forType:NSPasteboardTypeString];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(copy:))
        return self.copyText.length > 0;
    return YES;
}

/* The category tree in the configuration box */

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item
{
    return item ? ((PTTreeNode *)item).children.count : self.treeRoots.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item
{
    return item ? ((PTTreeNode *)item).children[i] : self.treeRoots[i];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item
{
    return ((PTTreeNode *)item).children.count > 0;
}

- (id)outlineView:(NSOutlineView *)ov
    objectValueForTableColumn:(NSTableColumn *)col byItem:(id)item
{
    return ((PTTreeNode *)item).title;
}

- (BOOL)outlineView:(NSOutlineView *)ov shouldEditTableColumn:(NSTableColumn *)c
               item:(id)item
{
    return NO;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)n
{
    PTTreeNode *node = [self.tree itemAtRow:self.tree.selectedRow];
    if (node)
        [self showPanel:node.panel];
}

- (void)showPanel:(int)which
{
    if (which == self.currpanel)
        return;
    for (NSUInteger i = 0; i < self.panels.count; i++)
        self.panels[i].hidden = ((int)i != which);
    self.currpanel = which;
}

@end

/* ----------------------------------------------------------------------
 * Laying out controls.
 */

static CGFloat fit_height(NSControl *c, CGFloat width)
{
    NSSize sz = [c.cell cellSizeForBounds:NSMakeRect(0, 0, width, 10000)];
    return ceil(sz.height);
}

static NSTextField *make_label(const char *text, CGFloat width,
                               CGFloat *height)
{
    NSTextField *l = [NSTextField wrappingLabelWithString:ns(text)];
    l.selectable = NO;
    *height = fit_height(l, width);
    l.frame = NSMakeRect(0, 0, width, *height);
    return l;
}

static NSTextField *make_entry(PTUCtrl *uc, bool password)
{
    NSTextField *f = password ? [[NSSecureTextField alloc] init] :
        [[NSTextField alloc] init];
    f.delegate = uc;
    f.lineBreakMode = NSLineBreakByClipping;
    f.cell.scrollable = YES;
    f.cell.wraps = NO;
    return f;
}

static CGFloat entry_height(void)
{
    static CGFloat h;
    if (!h) {
        NSTextField *f = [[NSTextField alloc] init];
        h = ceil(f.fittingSize.height);
        if (h < 20)
            h = 22;
    }
    return h;
}

static NSButton *make_button(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target
                                     action:action];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

/* Put a label on the left of a control, or above it if it's full width. */
static CGFloat place_labelled(NSView *tv, NSTextField *label, NSView *ctl,
                              CGFloat ctlh, CGFloat width, int percent)
{
    if (!label) {
        ctl.frame = NSMakeRect(0, 0, width, ctlh);
        [tv addSubview:ctl];
        return ctlh;
    }
    if (percent >= 100 || percent <= 0) {
        CGFloat lh = fit_height(label, width);
        label.frame = NSMakeRect(0, 0, width, lh);
        ctl.frame = NSMakeRect(0, lh + 2, width, ctlh);
        [tv addSubview:label];
        [tv addSubview:ctl];
        return lh + 2 + ctlh;
    }
    CGFloat cw = floor(width * percent / 100.0);
    CGFloat lw = width - cw - GAP;
    CGFloat lh = fit_height(label, lw);
    CGFloat h = MAX(lh, ctlh);
    label.frame = NSMakeRect(0, floor((h - lh) / 2), lw, lh);
    ctl.frame = NSMakeRect(width - cw, floor((h - ctlh) / 2), cw, ctlh);
    [tv addSubview:label];
    [tv addSubview:ctl];
    return h;
}

static PTUCtrl *make_control(PTDialog *d, dlgcontrol *c, CGFloat w, int panel)
{
    PTUCtrl *uc = [[PTUCtrl alloc] init];
    uc.dialog = d;
    uc.ctrl = c;
    uc.panel = panel;
    uc.items = [NSMutableArray array];
    uc.ids = [NSMutableArray array];

    PTFlipView *tv = [[PTFlipView alloc] initWithFrame:NSMakeRect(0, 0, w, 0)];
    CGFloat h = 0, lh;
    uc.toplevel = tv;

    switch (c->type) {
      case CTRL_TEXT: {
        NSTextField *t = [NSTextField wrappingLabelWithString:ns(c->label)];
        t.selectable = YES;
        if (!c->text.wrap) {
            t.cell.wraps = NO;
            t.lineBreakMode = NSLineBreakByTruncatingTail;
        }
        h = fit_height(t, w);
        t.frame = NSMakeRect(0, 0, w, h);
        [tv addSubview:t];
        uc.text = t;
        break;
      }

      case CTRL_EDITBOX: {
        NSTextField *field;
        CGFloat fh = entry_height();
        if (c->editbox.has_list) {
            NSComboBox *cb = [[NSComboBox alloc] init];
            cb.delegate = uc;
            cb.completes = NO;
            cb.usesDataSource = NO;
            cb.numberOfVisibleItems = 12;
            fh = MAX(fh, ceil(cb.fittingSize.height));
            uc.combo = cb;
            field = cb;
        } else {
            field = make_entry(uc, c->editbox.password);
            uc.entry = field;
        }
        if (c->label)
            uc.label = make_label(c->label, w, &lh);
        h = place_labelled(tv, uc.label, field, fh, w,
                           c->editbox.percentwidth);
        [d registerView:field forUC:uc];
        break;
      }

      case CTRL_RADIO: {
        CGFloat y = 0;
        if (c->label) {
            uc.label = make_label(c->label, w, &lh);
            [tv addSubview:uc.label];
            y = lh + 2;
        }
        int ncols = c->radio.ncolumns > 0 ? c->radio.ncolumns : 1;
        CGFloat colw = floor((w - GAP * (ncols - 1)) / ncols);
        NSMutableArray *radios = [NSMutableArray array];
        CGFloat rowh = 0;
        for (int i = 0; i < c->radio.nbuttons; i++) {
            int col = i % ncols;
            if (col == 0 && i > 0) {
                y += rowh + 2;
                rowh = 0;
            }
            NSButton *b = [NSButton radioButtonWithTitle:
                                        ns(c->radio.buttons[i])
                                                  target:uc
                                                  action:@selector(radioChanged:)];
            b.cell.wraps = YES;
            b.cell.lineBreakMode = NSLineBreakByWordWrapping;
            CGFloat bh = fit_height(b, colw);
            b.frame = NSMakeRect(col * (colw + GAP), y, colw, bh);
            rowh = MAX(rowh, bh);
            [tv addSubview:b];
            [radios addObject:b];
            [d registerView:b forUC:uc];
        }
        uc.radios = radios;
        h = y + rowh;
        break;
      }

      case CTRL_CHECKBOX: {
        NSButton *b = [NSButton checkboxWithTitle:ns(c->label) target:uc
                                           action:@selector(checkboxChanged:)];
        b.cell.wraps = YES;
        b.cell.lineBreakMode = NSLineBreakByWordWrapping;
        h = fit_height(b, w);
        b.frame = NSMakeRect(0, 0, w, h);
        [tv addSubview:b];
        uc.button = b;
        [d registerView:b forUC:uc];
        break;
      }

      case CTRL_BUTTON: {
        NSButton *b = make_button(ns(c->label), uc, @selector(buttonPressed:));
        if (c->button.isdefault)
            b.keyEquivalent = @"\r";
        else if (c->button.iscancel)
            b.keyEquivalent = @"\033";
        h = ceil(b.fittingSize.height);
        b.frame = NSMakeRect(0, 0, w, h);
        [tv addSubview:b];
        uc.button = b;
        [d registerView:b forUC:uc];
        break;
      }

      case CTRL_LISTBOX: {
        if (c->label)
            uc.label = make_label(c->label, w, &lh);

        if (c->listbox.height == 0) {
            NSPopUpButton *p = [[NSPopUpButton alloc]
                                   initWithFrame:NSZeroRect pullsDown:NO];
            p.target = uc;
            p.action = @selector(popupChanged:);
            [p removeAllItems];
            uc.popup = p;
            h = place_labelled(tv, uc.label, p, ceil(p.fittingSize.height),
                               w, c->listbox.percentwidth);
            [d registerView:p forUC:uc];
            break;
        }

        CGFloat y = 0;
        if (uc.label) {
            [tv addSubview:uc.label];
            y = lh + 2;
        }

        NSTableView *t = [[NSTableView alloc] initWithFrame:NSZeroRect];
        t.headerView = nil;
        t.rowHeight = 17;
        t.allowsMultipleSelection = (c->listbox.multisel != 0);
        t.allowsEmptySelection = YES;
        t.allowsColumnReordering = NO;
        t.allowsColumnResizing = NO;
        if (@available(macOS 11.0, *))
            t.style = NSTableViewStylePlain;
        t.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
        t.target = uc;
        t.doubleAction = @selector(listDoubleClicked:);

        CGFloat listw = w;
        if (c->listbox.draglist)
            listw = w - 80 - GAP;

        NSScrollView *sv = [[NSScrollView alloc] init];
        sv.hasVerticalScroller = YES;
        sv.hasHorizontalScroller = NO;
        sv.autohidesScrollers = YES;
        sv.borderType = NSBezelBorder;
        int nrows = c->listbox.height > 0 ? c->listbox.height : 5;
        CGFloat svh = nrows * (t.rowHeight + t.intercellSpacing.height) + 4;
        sv.frame = NSMakeRect(0, y, listw, svh);
        CGFloat inner = [NSScrollView contentSizeForFrameSize:sv.frame.size
                                      horizontalScrollerClass:nil
                                        verticalScrollerClass:[NSScroller class]
                                                   borderType:NSBezelBorder
                                                  controlSize:NSControlSizeRegular
                                                scrollerStyle:NSScrollerStyleLegacy].width;

        int ncols = c->listbox.ncols > 0 ? c->listbox.ncols : 1;
        CGFloat used = 0;
        for (int i = 0; i < ncols; i++) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:
                                     [NSString stringWithFormat:@"%d", i]];
            col.editable = NO;
            CGFloat cw;
            if (i == ncols - 1)
                cw = inner - used - t.intercellSpacing.width * ncols;
            else
                cw = floor(inner * (c->listbox.percentages ?
                                    c->listbox.percentages[i] : 100) / 100.0);
            if (cw < 20)
                cw = 20;
            col.width = cw;
            used += cw;
            col.dataCell = [[NSTextFieldCell alloc] init];
            ((NSTextFieldCell *)col.dataCell).lineBreakMode =
                NSLineBreakByTruncatingTail;
            [t addTableColumn:col];
        }
        t.dataSource = uc;
        t.delegate = uc;
        sv.documentView = t;
        [tv addSubview:sv];
        uc.table = t;
        [d registerView:t forUC:uc];

        if (c->listbox.draglist) {
            NSButton *up = make_button(@"Up", uc, @selector(dragUp:));
            NSButton *down = make_button(@"Down", uc, @selector(dragDown:));
            CGFloat bh = ceil(up.fittingSize.height);
            up.frame = NSMakeRect(w - 80, y, 80, bh);
            down.frame = NSMakeRect(w - 80, y + bh + 2, 80, bh);
            [tv addSubview:up];
            [tv addSubview:down];
            [d registerView:up forUC:uc];
            [d registerView:down forUC:uc];
        }
        h = y + svh;
        break;
      }

      case CTRL_FILESELECT:
      case CTRL_FONTSELECT: {
        bool font = (c->type == CTRL_FONTSELECT);
        if (!font && c->fileselect.just_button) {
            NSButton *b = make_button(ns(c->label), uc,
                                      @selector(fileBrowse:));
            h = ceil(b.fittingSize.height);
            b.frame = NSMakeRect(0, 0, w, h);
            [tv addSubview:b];
            uc.button = b;
            [d registerView:b forUC:uc];
            break;
        }
        CGFloat y = 0;
        if (c->label) {
            uc.label = make_label(c->label, w, &lh);
            [tv addSubview:uc.label];
            y = lh + 2;
        }
        NSButton *b = make_button(font ? @"Change..." : @"Browse...", uc,
                                  font ? @selector(fontChange:) :
                                  @selector(fileBrowse:));
        CGFloat bw = MAX(90, ceil(b.fittingSize.width));
        CGFloat bh = ceil(b.fittingSize.height);
        CGFloat eh = entry_height();
        CGFloat rowh = MAX(bh, eh);
        NSTextField *f = make_entry(uc, false);
        f.frame = NSMakeRect(0, y + floor((rowh - eh) / 2), w - bw - GAP, eh);
        b.frame = NSMakeRect(w - bw, y + floor((rowh - bh) / 2), bw, bh);
        [tv addSubview:f];
        [tv addSubview:b];
        uc.entry = f;
        uc.button = b;
        [d registerView:f forUC:uc];
        [d registerView:b forUC:uc];
        h = y + rowh;
        break;
      }

      default:
        break;
    }

    tv.frame = NSMakeRect(0, 0, w, h);
    d.byctrl[key_for(c)] = uc;
    [d.uctrls addObject:uc];
    return uc;
}

/* Lay out the controls of one controlset in a flipped view. */
static NSView *layout_ctrls(PTDialog *d, struct controlset *s,
                            CGFloat width, int panel)
{
    PTFlipView *v = [[PTFlipView alloc] initWithFrame:
                                           NSMakeRect(0, 0, width, 0)];
    int ncols = 1;
    int pct[MAXCOLS] = { 100 };
    CGFloat coly[MAXCOLS] = { 0 };
    bool any = false;

    ctrlset_normalise_aligns(s);

    for (size_t i = 0; i < s->ncontrols; i++) {
        dlgcontrol *c = s->ctrls[i];

        if (c->type == CTRL_COLUMNS) {
            CGFloat maxy = 0;
            for (int j = 0; j < ncols; j++)
                maxy = MAX(maxy, coly[j]);
            ncols = c->columns.ncols;
            if (ncols < 1)
                ncols = 1;
            if (ncols > MAXCOLS)
                ncols = MAXCOLS;
            for (int j = 0; j < ncols; j++) {
                pct[j] = c->columns.percentages ?
                    c->columns.percentages[j] : 100 / ncols;
                coly[j] = maxy;
            }
            continue;
        }
        if (c->type == CTRL_TABDELAY)
            continue;

        int start = COLUMN_START(c->column), span = COLUMN_SPAN(c->column);
        if (start >= ncols)
            start = ncols - 1;
        if (start + span > ncols)
            span = ncols - start;

        int before = 0, within = 0;
        for (int j = 0; j < start; j++)
            before += pct[j];
        for (int j = start; j < start + span; j++)
            within += pct[j];
        CGFloat x = floor(width * before / 100.0);
        CGFloat w = floor(width * within / 100.0);
        if (start > 0) {
            x += GAP;
            w -= GAP;
        }
        if (start + span >= ncols)
            w = width - x;

        CGFloat y = 0;
        for (int j = start; j < start + span; j++)
            y = MAX(y, coly[j]);
        if (c->align_next_to) {
            PTUCtrl *ref = d.byctrl[key_for(c->align_next_to)];
            if (ref)
                y = MAX(y, NSMinY(ref.toplevel.frame));
        }

        PTUCtrl *uc = make_control(d, c, w, panel);
        NSRect f = uc.toplevel.frame;
        if (c->align_next_to) {
            /* Line the two controls up along their bottoms, which is
             * where the input part of most controls sits. */
            PTUCtrl *ref = d.byctrl[key_for(c->align_next_to)];
            if (ref && NSMinY(ref.toplevel.frame) == y) {
                CGFloat rh = NSHeight(ref.toplevel.frame);
                if (rh > f.size.height)
                    y += rh - f.size.height;
            }
        }
        f.origin = NSMakePoint(x, y);
        uc.toplevel.frame = f;
        [v addSubview:uc.toplevel];
        any = true;

        for (int j = start; j < start + span; j++)
            coly[j] = y + f.size.height + GAP;
    }

    CGFloat h = 0;
    for (int j = 0; j < ncols; j++)
        h = MAX(h, coly[j]);
    if (any)
        h -= GAP;
    v.frame = NSMakeRect(0, 0, width, MAX(h, 0));
    return v;
}

static void box_overheads(CGFloat *dw, CGFloat *dh)
{
    static CGFloat w, h;
    if (!w) {
        NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        b.title = @"Title";
        b.contentViewMargins = NSMakeSize(10, 8);
        NSSize inner = b.contentView.frame.size;
        w = 400 - inner.width;
        h = 300 - inner.height;
        if (w <= 0 || w > 80)
            w = 24;
        if (h <= 0 || h > 80)
            h = 34;
    }
    *dw = w;
    *dh = h;
}

/*
 * A whole controlset as it appears in a panel or simple dialog: a
 * panel title, a titled box of controls or bare controls.
 */
static NSView *set_view(PTDialog *d, struct controlset *s, CGFloat width,
                        int panel)
{
    if (!s->boxname && s->boxtitle) {
        NSTextField *t = [NSTextField wrappingLabelWithString:
                                          ns(s->boxtitle)];
        t.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
        CGFloat h = fit_height(t, width);
        t.frame = NSMakeRect(0, 0, width, h);
        return t;
    }

    if (s->boxtitle && *s->boxtitle) {
        CGFloat dw, dh;
        box_overheads(&dw, &dh);
        NSView *inner = layout_ctrls(d, s, width - dw, panel);
        NSBox *b = [[NSBox alloc] initWithFrame:
                                     NSMakeRect(0, 0, width,
                                                NSHeight(inner.frame) + dh)];
        b.title = ns(s->boxtitle);
        b.contentViewMargins = NSMakeSize(10, 8);
        inner.frame = NSMakeRect(0, 0, NSWidth(b.contentView.frame),
                                 NSHeight(inner.frame));
        /* The content view isn't flipped, so pin the controls to its
         * top in case the box came out taller than we asked. */
        CGFloat spare = NSHeight(b.contentView.frame) - NSHeight(inner.frame);
        if (spare > 0)
            inner.frame = NSOffsetRect(inner.frame, 0, spare);
        [b.contentView addSubview:inner];
        return b;
    }

    return layout_ctrls(d, s, width, panel);
}

static void focus_first_control(PTDialog *d, struct controlbox *b)
{
    for (size_t i = 0; i < b->nctrlsets; i++) {
        struct controlset *s = b->ctrlsets[i];
        if (!*s->pathname)
            continue;
        for (size_t j = 0; j < s->ncontrols; j++) {
            dlgcontrol *c = s->ctrls[j];
            if (c->type != CTRL_TABDELAY && c->type != CTRL_COLUMNS &&
                c->type != CTRL_TEXT && d.byctrl[key_for(c)]) {
                dlg_set_focus(c, &d->dp);
                d.lastfocus = c;
                return;
            }
        }
    }
}

static void place_window(NSWindow *w, NSWindow *parent)
{
    if (parent && parent.isVisible) {
        NSRect pf = parent.frame, f = w.frame;
        NSPoint o = NSMakePoint(NSMidX(pf) - f.size.width / 2,
                                NSMaxY(pf) - f.size.height - 40);
        NSRect vis = parent.screen ? parent.screen.visibleFrame :
            NSScreen.mainScreen.visibleFrame;
        o.x = MAX(NSMinX(vis), MIN(o.x, NSMaxX(vis) - f.size.width));
        o.y = MAX(NSMinY(vis), MIN(o.y, NSMaxY(vis) - f.size.height));
        [w setFrameOrigin:o];
    } else {
        [w center];
    }
}

static PTDialogWindow *make_dialog_window(PTDialog *d, NSString *title,
                                          NSSize size, bool closable)
{
    NSWindowStyleMask style = NSWindowStyleMaskTitled;
    if (closable)
        style |= NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    PTDialogWindow *w = [[PTDialogWindow alloc]
                            initWithContentRect:NSMakeRect(0, 0, size.width,
                                                           size.height)
                                      styleMask:style
                                        backing:NSBackingStoreBuffered
                                          defer:NO];
    w.releasedWhenClosed = NO;
    w.title = title;
    w.delegate = d;
    w.contentView = [[PTFlipView alloc] initWithFrame:
                                           NSMakeRect(0, 0, size.width,
                                                      size.height)];
    d.window = w;
    return w;
}

/*
 * A dialog with all its controlsets stacked vertically and the
 * button row (the controlset with an empty path) at the bottom: used
 * for the Event Log and the CA and SSHFP configuration boxes.
 */
static PTDialog *simple_dialog(struct controlbox *b, const char *title,
                               CGFloat width, void *data)
{
    PTDialog *d = [[PTDialog alloc] init];
    d.ctrlbox = b;
    d.ownsBox = true;
    d.data = data;

    NSMutableArray *views = [NSMutableArray array];
    NSView *buttons = nil;
    for (size_t i = 0; i < b->nctrlsets; i++) {
        struct controlset *s = b->ctrlsets[i];
        if (!*s->pathname)
            buttons = layout_ctrls(d, s, width, -1);
        else
            [views addObject:set_view(d, s, width, -1)];
    }

    CGFloat y = MARGIN;
    for (NSView *v in views) {
        v.frame = NSMakeRect(MARGIN, y, width, NSHeight(v.frame));
        y += NSHeight(v.frame) + GAP * 2;
    }
    if (buttons) {
        y += GAP;
        buttons.frame = NSMakeRect(MARGIN, y, width, NSHeight(buttons.frame));
        y += NSHeight(buttons.frame) + GAP * 2;
    }
    y += MARGIN - GAP * 2;

    /* Very tall boxes scroll. */
    CGFloat maxh = NSScreen.mainScreen.visibleFrame.size.height - 80;
    PTFlipView *doc = [[PTFlipView alloc] initWithFrame:
                                             NSMakeRect(0, 0, width + 2*MARGIN,
                                                        y)];
    for (NSView *v in views)
        [doc addSubview:v];
    if (buttons)
        [doc addSubview:buttons];

    CGFloat h = MIN(y, maxh);
    PTDialogWindow *w = make_dialog_window(
        d, ns(title), NSMakeSize(width + 2*MARGIN, h), true);
    if (h < y) {
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
                                                    NSMakeRect(0, 0,
                                                               width + 2*MARGIN,
                                                               h)];
        sv.hasVerticalScroller = YES;
        sv.drawsBackground = NO;
        sv.documentView = doc;
        [w.contentView addSubview:sv];
    } else {
        [w.contentView addSubview:doc];
    }

    dlg_refresh(NULL, &d->dp);
    return d;
}

/* ----------------------------------------------------------------------
 * The configuration box.
 */

#define TREE_W 190
#define PANEL_W 470
#define PANEL_H 470

void macos_config_box(const char *title, Conf *conf, bool midsession,
                      int protcfginfo, void *parentwin,
                      macos_dialog_done_fn after, void *afterctx)
{
    PTDialog *d = [[PTDialog alloc] init];
    d.after = after;
    d.afterctx = afterctx;
    d.retval = 0;

    struct controlbox *b = ctrl_new_box();
    int protocol = conf_get_int(conf, CONF_protocol);
    setup_config_box(b, midsession, protocol, protcfginfo);
    unix_setup_config_box(b, midsession, protocol);
    macos_setup_config_box(b, midsession);
    d.ctrlbox = b;
    d.ownsBox = true;

    CGFloat docw = PANEL_W - 20;       /* leave room for a scroll bar */
    NSMutableArray<NSMutableArray<NSView *> *> *panelviews =
        [NSMutableArray array];
    NSMutableArray<PTTreeNode *> *roots = [NSMutableArray array];
    NSMutableArray<PTTreeNode *> *stack = [NSMutableArray array];
    NSView *buttons = nil;
    const char *path = NULL;

    for (size_t i = 0; i < b->nctrlsets; i++) {
        struct controlset *s = b->ctrlsets[i];

        if (!*s->pathname) {
            buttons = layout_ctrls(d, s, TREE_W + MARGIN + PANEL_W, -1);
            continue;
        }

        int j = path ? ctrl_path_compare(s->pathname, path) : 0;
        if (j != INT_MAX) {
            /* A new panel, with its own entry in the tree. */
            int depth = ctrl_path_elements(s->pathname);
            const char *leaf = strrchr(s->pathname, '/');
            leaf = leaf ? leaf + 1 : s->pathname;

            PTTreeNode *node = [[PTTreeNode alloc] init];
            node.title = ns(leaf);
            node.children = [NSMutableArray array];
            node.panel = (int)panelviews.count;
            while ((int)stack.count >= depth)
                [stack removeLastObject];
            if (stack.count)
                [stack.lastObject.children addObject:node];
            else
                [roots addObject:node];
            [stack addObject:node];

            [panelviews addObject:[NSMutableArray array]];
            path = s->pathname;
        }

        [panelviews.lastObject addObject:
             set_view(d, s, docw, (int)panelviews.count - 1)];
    }

    CGFloat btnh = buttons ? NSHeight(buttons.frame) : 0;
    NSSize size = NSMakeSize(MARGIN + TREE_W + MARGIN + PANEL_W + MARGIN,
                             MARGIN + PANEL_H + MARGIN + btnh + MARGIN);
    PTDialogWindow *w = make_dialog_window(d, ns(title), size, true);
    NSView *content = w.contentView;

    /* The panels */
    d.panels = [NSMutableArray array];
    for (NSMutableArray<NSView *> *views in panelviews) {
        CGFloat y = 0;
        for (NSView *v in views)
            y += NSHeight(v.frame) + GAP * 2;
        PTFlipView *doc = [[PTFlipView alloc] initWithFrame:
                                                 NSMakeRect(0, 0, docw,
                                                            MAX(y, PANEL_H))];
        y = 0;
        for (NSView *v in views) {
            v.frame = NSMakeRect(0, y, docw, NSHeight(v.frame));
            [doc addSubview:v];
            y += NSHeight(v.frame) + GAP * 2;
        }
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
                                                    NSMakeRect(MARGIN + TREE_W
                                                               + MARGIN,
                                                               MARGIN,
                                                               PANEL_W,
                                                               PANEL_H)];
        sv.hasVerticalScroller = YES;
        sv.autohidesScrollers = YES;
        sv.drawsBackground = NO;
        sv.borderType = NSNoBorder;
        sv.documentView = doc;
        sv.hidden = YES;
        [content addSubview:sv];
        [d.panels addObject:sv];
    }

    /* The category tree */
    NSScrollView *tsv = [[NSScrollView alloc] initWithFrame:
                                                 NSMakeRect(MARGIN, MARGIN,
                                                            TREE_W, PANEL_H)];
    tsv.hasVerticalScroller = YES;
    tsv.autohidesScrollers = YES;
    tsv.borderType = NSBezelBorder;
    NSOutlineView *tree = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    col.editable = NO;
    col.width = TREE_W - 4;
    [tree addTableColumn:col];
    tree.outlineTableColumn = col;
    tree.headerView = nil;
    tree.allowsEmptySelection = NO;
    tree.allowsMultipleSelection = NO;
    tree.indentationPerLevel = 14;
    if (@available(macOS 11.0, *))
        tree.style = NSTableViewStylePlain;
    tree.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    d.treeRoots = roots;
    d.tree = tree;
    tree.dataSource = d;
    tree.delegate = d;
    tsv.documentView = tree;
    [content addSubview:tsv];
    [tree reloadData];
    [tree expandItem:nil expandChildren:YES];

    if (buttons) {
        buttons.frame = NSMakeRect(MARGIN, MARGIN + PANEL_H + MARGIN,
                                   NSWidth(buttons.frame), btnh);
        [content addSubview:buttons];
    }

    d.data = conf;
    dlg_refresh(NULL, &d->dp);

    [d showPanel:0];
    [tree selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
      byExtendingSelection:NO];

    place_window(w, (__bridge NSWindow *)parentwin);
    focus_first_control(d, b);
    [w makeKeyAndOrderFront:nil];
}

/* ----------------------------------------------------------------------
 * The dlg_* functions called by the portable dialog code.
 */

static NSTextField *edit_field(PTUCtrl *uc)
{
    return uc.combo ? uc.combo : uc.entry;
}

void dlg_radiobutton_set(dlgcontrol *ctrl, dlgparam *dp, int which)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_RADIO);
    for (NSUInteger i = 0; i < uc.radios.count; i++)
        uc.radios[i].state = ((int)i == which) ? NSControlStateValueOn :
            NSControlStateValueOff;
}

int dlg_radiobutton_get(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_RADIO);
    for (NSUInteger i = 0; i < uc.radios.count; i++)
        if (uc.radios[i].state == NSControlStateValueOn)
            return (int)i;
    return 0;
}

void dlg_checkbox_set(dlgcontrol *ctrl, dlgparam *dp, bool checked)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_CHECKBOX);
    uc.button.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
}

bool dlg_checkbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_CHECKBOX);
    return uc.button.state == NSControlStateValueOn;
}

void dlg_editbox_set_utf8(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_EDITBOX);
    /*
     * Copy the text before doing anything: it probably points into
     * the Conf, which the VALCHANGE handler below writes to.
     */
    NSString *str = ns(text);
    NSTextField *f = edit_field(uc);
    if ([f.stringValue isEqualToString:str])
        return;
    f.stringValue = str;
    /* As in the GTK and Windows front ends, setting an edit box's
     * contents counts as a change to it. */
    [uc send:EVENT_VALCHANGE];
}

void dlg_editbox_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    /* Our edit boxes are UTF-8, like GTK's. */
    dlg_editbox_set_utf8(ctrl, dp, text);
}

char *dlg_editbox_get_utf8(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_EDITBOX);
    return dupns(edit_field(uc).stringValue);
}

char *dlg_editbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    return dlg_editbox_get_utf8(ctrl, dp);
}

void dlg_editbox_select_range(dlgcontrol *ctrl, dlgparam *dp,
                              size_t start, size_t len)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_EDITBOX);
    NSTextField *f = edit_field(uc);
    NSWindow *w = DLG(dp).window;
    if (![w makeFirstResponder:f])
        return;
    NSText *editor = [w fieldEditor:NO forObject:f];
    NSUInteger n = f.stringValue.length;
    if (start > n)
        start = n;
    if (start + len > n)
        len = n - start;
    editor.selectedRange = NSMakeRange(start, len);
}

static void list_reload(PTUCtrl *uc)
{
    uc.suppress = true;
    [uc.table reloadData];
    uc.suppress = false;
}

void dlg_listbox_clear(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    [uc.items removeAllObjects];
    [uc.ids removeAllObjects];
    uc.suppress = true;
    if (uc.table) {
        [uc.table deselectAll:nil];
        [uc.table reloadData];
    }
    [uc.popup removeAllItems];
    [uc.combo removeAllItems];
    uc.suppress = false;
}

void dlg_listbox_del(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    PTUCtrl *uc = UC(ctrl, dp);
    if (index < 0 || index >= (int)uc.items.count)
        return;
    [uc.items removeObjectAtIndex:index];
    [uc.ids removeObjectAtIndex:index];
    uc.suppress = true;
    if (uc.table) {
        [uc.table removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:index]
                        withAnimation:NSTableViewAnimationEffectNone];
        [uc.table reloadData];
    }
    if (uc.popup)
        [uc.popup removeItemAtIndex:index];
    if (uc.combo)
        [uc.combo removeItemAtIndex:index];
    uc.suppress = false;
}

void dlg_listbox_add(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    dlg_listbox_addwithid(ctrl, dp, text, 0);
}

void dlg_listbox_addwithid(dlgcontrol *ctrl, dlgparam *dp,
                           char const *text, int id)
{
    PTUCtrl *uc = UC(ctrl, dp);
    NSString *s = ns(text);
    [uc.items addObject:s];
    [uc.ids addObject:@(id)];
    uc.suppress = true;
    if (uc.table)
        [uc.table reloadData];
    if (uc.popup) {
        /* Not addItemWithTitle:, which refuses duplicates. */
        [uc.popup.menu addItemWithTitle:s action:NULL keyEquivalent:@""];
    }
    if (uc.combo)
        [uc.combo addItemWithObjectValue:s];
    uc.suppress = false;
}

int dlg_listbox_getid(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    PTUCtrl *uc = UC(ctrl, dp);
    if (index < 0 || index >= (int)uc.ids.count)
        return 0;
    return uc.ids[index].intValue;
}

int dlg_listbox_index(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    if (uc.table) {
        NSIndexSet *sel = uc.table.selectedRowIndexes;
        return sel.count == 1 ? (int)sel.firstIndex : -1;
    }
    if (uc.popup)
        return (int)uc.popup.indexOfSelectedItem;
    if (uc.combo)
        return (int)uc.combo.indexOfSelectedItem;
    return -1;
}

bool dlg_listbox_issel(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    PTUCtrl *uc = UC(ctrl, dp);
    if (uc.table)
        return [uc.table.selectedRowIndexes containsIndex:index];
    if (uc.popup)
        return uc.popup.indexOfSelectedItem == index;
    if (uc.combo)
        return uc.combo.indexOfSelectedItem == index;
    return false;
}

void dlg_listbox_select(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    PTUCtrl *uc = UC(ctrl, dp);
    if (index < 0 || index >= (int)uc.items.count)
        return;
    uc.suppress = true;
    if (uc.table) {
        [uc.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
              byExtendingSelection:NO];
        [uc.table scrollRowToVisible:index];
    }
    if (uc.popup)
        [uc.popup selectItemAtIndex:index];
    if (uc.combo)
        [uc.combo selectItemAtIndex:index];
    uc.suppress = false;
}

void dlg_text_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_TEXT);
    uc.text.stringValue = ns(text);
}

void dlg_label_change(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    PTUCtrl *uc = UC(ctrl, dp);
    switch (ctrl->type) {
      case CTRL_BUTTON:
      case CTRL_CHECKBOX:
        uc.button.title = ns(text);
        break;
      case CTRL_FILESELECT:
        if (uc.label)
            uc.label.stringValue = ns(text);
        else
            uc.button.title = ns(text);
        break;
      default:
        uc.label.stringValue = ns(text);
        break;
    }
}

void dlg_filesel_set(dlgcontrol *ctrl, dlgparam *dp, Filename *fn)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_FILESELECT);
    if (uc.entry)
        uc.entry.stringValue = ns(fn->path);
}

Filename *dlg_filesel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_FILESELECT);
    NSString *s = uc.entry ? uc.entry.stringValue : uc.textvalue;
    const char *u = s.UTF8String;
    return filename_from_str(u ? u : "");
}

void dlg_fontsel_set(dlgcontrol *ctrl, dlgparam *dp, FontSpec *fs)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_FONTSELECT);
    uc.entry.stringValue = ns(fs->name);
}

FontSpec *dlg_fontsel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    assert(ctrl->type == CTRL_FONTSELECT);
    const char *u = uc.entry.stringValue.UTF8String;
    return fontspec_new(u ? u : "");
}

void dlg_update_start(dlgcontrol *ctrl, dlgparam *dp)
{
    /* AppKit coalesces redraws anyway. */
}

void dlg_update_done(dlgcontrol *ctrl, dlgparam *dp)
{
}

void dlg_set_focus(dlgcontrol *ctrl, dlgparam *dp)
{
    PTUCtrl *uc = UC(ctrl, dp);
    NSView *v = uc.table ? (NSView *)uc.table : uc.combo ? uc.combo :
        uc.entry ? uc.entry : uc.popup ? uc.popup :
        uc.radios.count ? uc.radios[0] : uc.button;
    if (v)
        [DLG(dp).window makeFirstResponder:v];
}

dlgcontrol *dlg_last_focused(dlgcontrol *ctrl, dlgparam *dp)
{
    PTDialog *d = DLG(dp);
    return d.currfocus != ctrl ? d.currfocus : d.lastfocus;
}

bool dlg_is_visible(dlgcontrol *ctrl, dlgparam *dp)
{
    PTDialog *d = DLG(dp);
    PTUCtrl *uc = d.byctrl[key_for(ctrl)];
    return uc && (uc.panel < 0 || uc.panel == d.currpanel);
}

void dlg_beep(dlgparam *dp)
{
    NSBeep();
}

void dlg_error_msg(dlgparam *dp, const char *msg)
{
    static const char *const ok[] = { "OK" };
    macos_message_box((__bridge void *)DLG(dp).window, "Error", msg, false,
                      ok, 1, NULL, NULL);
}

void dlg_end(dlgparam *dp, int value)
{
    [DLG(dp) endWithValue:value];
}

void dlg_refresh(dlgcontrol *ctrl, dlgparam *dp)
{
    PTDialog *d = DLG(dp);
    if (ctrl) {
        if (ctrl->handler)
            ctrl->handler(ctrl, dp, d.data, EVENT_REFRESH);
        return;
    }
    for (PTUCtrl *uc in [d.uctrls copy]) {
        dlgcontrol *c = uc.ctrl;
        if (c && c->handler && !d.ended)
            c->handler(c, dp, d.data, EVENT_REFRESH);
    }
}

void dlg_coloursel_start(dlgcontrol *ctrl, dlgparam *dp, int r, int g, int b)
{
    PTDialog *d = DLG(dp);
    PTUCtrl *uc = UC(ctrl, dp);

    NSColorWell *well = [[NSColorWell alloc] initWithFrame:
                                                NSMakeRect(0, 0, 160, 32)];
    well.color = [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0
                                      blue:b / 255.0 alpha:1.0];
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    cp.showsAlpha = NO;

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Select a colour";
    a.informativeText = @"Click the colour to change it.";
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:@"Cancel"];
    a.accessoryView = well;
    [a beginSheetModalForWindow:d.window
              completionHandler:^(NSModalResponse resp) {
        [well deactivate];
        [cp orderOut:nil];
        if (d.ended)
            return;
        NSColor *c = [well.color colorUsingColorSpace:
                                     [NSColorSpace sRGBColorSpace]];
        d.colok = (resp == NSAlertFirstButtonReturn && c != nil);
        if (d.colok) {
            d.colr = (int)lround(c.redComponent * 255);
            d.colg = (int)lround(c.greenComponent * 255);
            d.colb = (int)lround(c.blueComponent * 255);
        }
        [uc send:EVENT_CALLBACK];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        [well activate:YES];
    });
}

bool dlg_coloursel_results(dlgcontrol *ctrl, dlgparam *dp,
                           int *r, int *g, int *b)
{
    PTDialog *d = DLG(dp);
    if (!d.colok)
        return false;
    *r = d.colr;
    *g = d.colg;
    *b = d.colb;
    return true;
}

/* ----------------------------------------------------------------------
 * Message boxes.
 */

@interface PTMessageBox : NSObject
@property (strong) NSAlert *alert;
@property (strong) NSWindow *parent;
@property (assign) macos_dialog_done_fn after;
@property (assign) void *afterctx;
@property bool done;
@property NSInteger extraTag;              /* button that doesn't close */
@property (copy) void (^extraAction)(void);
@end

static NSMutableSet *open_boxes;

@implementation PTMessageBox

- (void)pressed:(NSButton *)b
{
    if (self.extraAction && b.tag == self.extraTag) {
        self.extraAction();
        return;
    }
    [self finish:(int)b.tag];
}

- (void)finish:(int)result
{
    if (self.done)
        return;
    self.done = true;
    if (self.parent)
        [self.parent endSheet:self.alert.window];
    else
        [self.alert.window orderOut:nil];
    self.extraAction = nil;
    macos_dialog_done_fn after = self.after;
    self.after = NULL;
    if (after)
        after(self.afterctx, result);
    /* We may be inside one of our own buttons' actions, so don't let
     * go of the alert until we're back in the event loop. */
    PTMessageBox *me = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [open_boxes removeObject:me];
    });
}

@end

static PTMessageBox *message_box_general(
    NSWindow *parent, const char *title, const char *msg, bool critical,
    const char *const *buttons, int nbuttons,
    macos_dialog_done_fn after, void *afterctx, NSView *accessory)
{
    if (!open_boxes)
        open_boxes = [NSMutableSet set];

    PTMessageBox *mb = [[PTMessageBox alloc] init];
    mb.after = after;
    mb.afterctx = afterctx;
    mb.extraTag = -1;

    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle = critical ? NSAlertStyleCritical : NSAlertStyleWarning;
    a.messageText = ns(title);
    a.informativeText = msg ? ns(msg) : @"";
    for (int i = 0; i < nbuttons; i++) {
        NSButton *b = [a addButtonWithTitle:ns(buttons[i])];
        b.tag = i;
        b.target = mb;
        b.action = @selector(pressed:);
    }
    if (accessory)
        a.accessoryView = accessory;
    mb.alert = a;
    [open_boxes addObject:mb];

    if (parent && parent.isVisible) {
        mb.parent = parent;
        [a layout];
        [parent beginSheet:a.window completionHandler:nil];
    } else {
        [a layout];
        [a.window center];
        [a.window makeKeyAndOrderFront:nil];
    }
    return mb;
}

void *macos_message_box(void *parentwin, const char *title,
                        const char *msg, bool critical,
                        const char *const *buttons, int nbuttons,
                        macos_dialog_done_fn after, void *afterctx)
{
    PTMessageBox *mb = message_box_general(
        (__bridge NSWindow *)parentwin, title, msg, critical,
        buttons, nbuttons, after, afterctx, nil);
    return (__bridge void *)mb;
}

void macos_cancel_message_box(void *box)
{
    PTMessageBox *mb = (__bridge PTMessageBox *)box;
    [mb finish:-1];
}

/* A read-only, selectable, scrolling block of text for a message box. */
static NSView *text_accessory(const char *text, bool mono, CGFloat width,
                              CGFloat maxheight)
{
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
                                                NSMakeRect(0, 0, width,
                                                           maxheight)];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:
                                            NSMakeRect(0, 0, width, maxheight)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.string = ns(text);
    tv.font = mono ?
        [NSFont userFixedPitchFontOfSize:[NSFont smallSystemFontSize]] :
        [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    tv.textContainerInset = NSMakeSize(4, 4);
    tv.verticallyResizable = YES;
    tv.autoresizingMask = NSViewWidthSizable;
    [tv.layoutManager ensureLayoutForTextContainer:tv.textContainer];
    CGFloat h = [tv.layoutManager usedRectForTextContainer:
                                      tv.textContainer].size.height + 12;
    if (h < maxheight)
        sv.frame = NSMakeRect(0, 0, width, MAX(h, 40));
    sv.documentView = tv;
    return sv;
}

/* ----------------------------------------------------------------------
 * The security prompts.
 */

const SeatDialogPromptDescriptions *macos_seat_prompt_descriptions(Seat *seat)
{
    static const SeatDialogPromptDescriptions descs = {
        .hk_accept_action = "press \"Accept\"",
        .hk_connect_once_action = "press \"Connect Once\"",
        .hk_cancel_action = "press \"Cancel\"",
        .hk_cancel_action_Participle = "Pressing \"Cancel\"",
        .weak_accept_action = "press \"Yes\"",
        .weak_cancel_action = "press \"No\"",
    };
    return &descs;
}

/* Turn a SeatDialogText into the text of a message box; returns the
 * title. */
static const char *format_seatdialogtext(SeatDialogText *text,
                                         strbuf *dlg_text)
{
    const char *dlg_title = NULL;

    for (SeatDialogTextItem *item = text->items,
             *end = item + text->nitems; item < end; item++) {
        switch (item->type) {
          case SDT_PARA:
          case SDT_DISPLAY:
          case SDT_SCARY_HEADING:
            put_fmt(dlg_text, "%s\n\n", item->text);
            break;
          case SDT_TITLE:
            dlg_title = item->text;
            break;
          default:
            break;
        }
    }
    while (strbuf_chomp(dlg_text, '\n'));

    return dlg_title ? dlg_title : appname;
}

struct hostkey_ctx {
    void (*callback)(void *ctx, SeatPromptResult result);
    void *callback_ctx;
    Seat *seat;
    char *host, *keytype, *keystr, *more_info;
    int port;
    void *box, *infobox;
};

static void more_info_closed(void *vctx, int result)
{
    struct hostkey_ctx *ctx = (struct hostkey_ctx *)vctx;
    ctx->infobox = NULL;
}

static void hostkey_result(void *vctx, int result)
{
    struct hostkey_ctx *ctx = (struct hostkey_ctx *)vctx;

    macos_frontend_unregister_dialog(ctx->seat, ctx->box);
    if (ctx->infobox)
        macos_cancel_message_box(ctx->infobox);

    /* Buttons: Accept, Connect Once, Cancel */
    if (result >= 0) {
        SeatPromptResult spr;
        if (result == 0) {
            store_host_key(ctx->seat, ctx->host, ctx->port,
                           ctx->keytype, ctx->keystr);
            spr = SPR_OK;
        } else if (result == 1) {
            spr = SPR_OK;
        } else {
            spr = SPR_USER_ABORT;
        }
        ctx->callback(ctx->callback_ctx, spr);
    }

    sfree(ctx->host);
    sfree(ctx->keytype);
    sfree(ctx->keystr);
    sfree(ctx->more_info);
    sfree(ctx);
}

SeatPromptResult macos_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    static const char *const buttons[] = {
        "Accept", "Connect Once", "Cancel", "More info...",
    };

    strbuf *dlg_text = strbuf_new();
    const char *dlg_title = format_seatdialogtext(text, dlg_text);

    struct hostkey_ctx *hc = snew(struct hostkey_ctx);
    memset(hc, 0, sizeof(*hc));
    hc->callback = callback;
    hc->callback_ctx = ctx;
    hc->seat = seat;
    hc->host = dupstr(host);
    hc->port = port;
    hc->keytype = dupstr(keytype);
    hc->keystr = dupstr(keystr);

    strbuf *moreinfo = strbuf_new();
    for (SeatDialogTextItem *item = text->items,
             *end = item + text->nitems; item < end; item++) {
        switch (item->type) {
          case SDT_MORE_INFO_KEY:
            put_fmt(moreinfo, "%s", item->text);
            break;
          case SDT_MORE_INFO_VALUE_SHORT:
            put_fmt(moreinfo, ": %s\n", item->text);
            break;
          case SDT_MORE_INFO_VALUE_BLOB:
            put_fmt(moreinfo, ":\n%s\n", item->text);
            break;
          default:
            break;
        }
    }
    hc->more_info = strbuf_to_str(moreinfo);

    PTMessageBox *mb = message_box_general(
        (__bridge NSWindow *)macos_seat_window(seat), dlg_title, dlg_text->s,
        true, buttons, lenof(buttons), hostkey_result, hc, nil);
    strbuf_free(dlg_text);

    /* Don't let a stray Return accept a new host key. */
    NSArray<NSButton *> *bs = mb.alert.buttons;
    bs[0].keyEquivalent = @"";
    bs[2].keyEquivalent = @"\033";

    NSWindow *alertwin = mb.alert.window;
    mb.extraTag = 3;
    mb.extraAction = ^{
        if (hc->infobox)
            return;
        static const char *const ok[] = { "OK" };
        NSView *acc = text_accessory(hc->more_info, true, 520, 200);
        PTMessageBox *ib = message_box_general(
            alertwin, "Host key information", NULL, false, ok, 1,
            more_info_closed, hc, acc);
        hc->infobox = (__bridge void *)ib;
    };

    hc->box = (__bridge void *)mb;
    macos_frontend_register_dialog(seat, hc->box);

    return SPR_INCOMPLETE;
}

struct simple_spr_ctx {
    void (*callback)(void *ctx, SeatPromptResult result);
    void *callback_ctx;
    Seat *seat;
    void *box;
};

static void simple_spr_result(void *vctx, int result)
{
    struct simple_spr_ctx *ctx = (struct simple_spr_ctx *)vctx;
    macos_frontend_unregister_dialog(ctx->seat, ctx->box);
    /* Buttons: Yes, No */
    if (result == 0)
        ctx->callback(ctx->callback_ctx, SPR_OK);
    else if (result > 0)
        ctx->callback(ctx->callback_ctx, SPR_USER_ABORT);
    sfree(ctx);
}

static SeatPromptResult simple_yes_no(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    static const char *const buttons[] = { "Yes", "No" };

    strbuf *dlg_text = strbuf_new();
    const char *dlg_title = format_seatdialogtext(text, dlg_text);

    struct simple_spr_ctx *sc = snew(struct simple_spr_ctx);
    sc->callback = callback;
    sc->callback_ctx = ctx;
    sc->seat = seat;

    PTMessageBox *mb = message_box_general(
        (__bridge NSWindow *)macos_seat_window(seat), dlg_title, dlg_text->s,
        false, buttons, lenof(buttons), simple_spr_result, sc, nil);
    strbuf_free(dlg_text);

    sc->box = (__bridge void *)mb;
    macos_frontend_register_dialog(seat, sc->box);
    return SPR_INCOMPLETE;
}

SeatPromptResult macos_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return simple_yes_no(seat, text, callback, ctx);
}

SeatPromptResult macos_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return simple_yes_no(seat, text, callback, ctx);
}

struct askappend_ctx {
    void (*callback)(void *ctx, int result);
    void *callback_ctx;
    Seat *seat;
    void *box;
};

static void askappend_result(void *vctx, int result)
{
    struct askappend_ctx *ctx = (struct askappend_ctx *)vctx;
    macos_frontend_unregister_dialog(ctx->seat, ctx->box);
    /* Buttons: Overwrite (2), Append (1), Disable (0) */
    if (result >= 0)
        ctx->callback(ctx->callback_ctx, 2 - result);
    sfree(ctx);
}

int macos_askappend(Seat *seat, Filename *filename,
                    void (*callback)(void *ctx, int result), void *ctx)
{
    static const char *const buttons[] = { "Overwrite", "Append", "Disable" };

    char *message = dupprintf(
        "The session log file \"%s\" already exists. "
        "You can overwrite it with a new session log, "
        "append your session log to the end of it, "
        "or disable session logging for this session.", filename->path);
    char *title = dupprintf("%s Log to File", appname);

    struct askappend_ctx *ac = snew(struct askappend_ctx);
    ac->callback = callback;
    ac->callback_ctx = ctx;
    ac->seat = seat;

    PTMessageBox *mb = message_box_general(
        (__bridge NSWindow *)macos_seat_window(seat), title, message, false,
        buttons, lenof(buttons), askappend_result, ac, nil);
    ac->box = (__bridge void *)mb;
    macos_frontend_register_dialog(seat, ac->box);

    sfree(message);
    sfree(title);
    return -1;                         /* dialog still in progress */
}

/* ----------------------------------------------------------------------
 * The About box.
 */

static void *aboutbox, *licencebox;

static void licence_closed(void *ctx, int result)
{
    licencebox = NULL;
}

static void about_result(void *ctx, int result)
{
    aboutbox = NULL;
    if (licencebox)
        macos_cancel_message_box(licencebox);
}

void macos_about_box(void *parentwin)
{
    if (aboutbox) {
        [((__bridge PTMessageBox *)aboutbox).alert.window
            makeKeyAndOrderFront:nil];
        return;
    }

    static const char *const buttons[] = { "Close", "View Licence" };
    char *buildinfo_text = buildinfo("\n");
    char *text = dupprintf(
        "%s\n\n%s\n\nCopyright " SHORT_COPYRIGHT_DETAILS
        ". All rights reserved", ver, buildinfo_text);
    char *title = dupcat("About ", appname);

    PTMessageBox *mb = message_box_general(
        nil, appname, NULL, false, buttons, lenof(buttons),
        about_result, NULL, text_accessory(text, false, 420, 220));
    mb.alert.window.title = ns(title);
    mb.alert.alertStyle = NSAlertStyleInformational;
    mb.extraTag = 1;
    mb.extraAction = ^{
        if (licencebox)
            return;
        static const char *const ok[] = { "OK" };
        char *lt = dupcat(appname, " Licence");
        PTMessageBox *lb = message_box_general(
            nil, lt, NULL, false, ok, 1, licence_closed, NULL,
            text_accessory(LICENCE_TEXT("\n\n"), false, 480, 320));
        sfree(lt);
        licencebox = (__bridge void *)lb;
    };
    aboutbox = (__bridge void *)mb;

    sfree(buildinfo_text);
    sfree(text);
    sfree(title);
}

/* ----------------------------------------------------------------------
 * The Event Log.
 */

#define LOGEVENT_INITIAL_MAX 128
#define LOGEVENT_CIRCULAR_MAX 128

struct eventlog_stuff {
    void *dialog;                      /* PTDialog, if the window is open */
    dlgcontrol *listctrl;
    char **events_initial;
    char **events_circular;
    int ninitial, ncircular, circular_first;
    strbuf *seldata;
};

static void eventlog_ok_handler(dlgcontrol *ctrl, dlgparam *dp,
                                void *data, int event)
{
    if (event == EVENT_ACTION)
        dlg_end(dp, 0);
}

static void eventlog_list_handler(dlgcontrol *ctrl, dlgparam *dp,
                                  void *data, int event)
{
    eventlog_stuff *es = (eventlog_stuff *)data;

    if (event == EVENT_REFRESH) {
        dlg_update_start(ctrl, dp);
        dlg_listbox_clear(ctrl, dp);
        for (int i = 0; i < es->ninitial; i++)
            dlg_listbox_add(ctrl, dp, es->events_initial[i]);
        for (int i = 0; i < es->ncircular; i++)
            dlg_listbox_add(ctrl, dp, es->events_circular[
                                (es->circular_first + i) %
                                LOGEVENT_CIRCULAR_MAX]);
        dlg_update_done(ctrl, dp);
    } else if (event == EVENT_SELCHANGE) {
        /* Selected lines can be copied with Command-C. */
        strbuf_clear(es->seldata);
        for (int i = 0; i < es->ninitial; i++) {
            if (dlg_listbox_issel(ctrl, dp, i))
                put_fmt(es->seldata, "%s\n", es->events_initial[i]);
        }
        for (int i = 0; i < es->ncircular; i++) {
            if (dlg_listbox_issel(ctrl, dp, es->ninitial + i)) {
                int j = (es->circular_first + i) % LOGEVENT_CIRCULAR_MAX;
                put_fmt(es->seldata, "%s\n", es->events_circular[j]);
            }
        }
        DLG(dp).copyText = ns(es->seldata->s);
    }
}

void showeventlog(eventlog_stuff *es, void *parentwin)
{
    if (es->dialog) {
        [((__bridge PTDialog *)es->dialog).window makeKeyAndOrderFront:nil];
        return;
    }

    struct controlbox *b = ctrl_new_box();
    struct controlset *s0, *s1;
    dlgcontrol *c;

    s0 = ctrl_getset(b, "", "", "");
    ctrl_columns(s0, 3, 33, 34, 33);
    c = ctrl_pushbutton(s0, "Close", 'c', HELPCTX(no_help),
                        eventlog_ok_handler, P(NULL));
    c->column = 2;
    c->button.isdefault = true;

    s1 = ctrl_getset(b, "x", "", "");
    es->listctrl = c = ctrl_listbox(s1, NULL, NO_SHORTCUT, HELPCTX(no_help),
                                    eventlog_list_handler, P(es));
    c->listbox.height = 16;
    c->listbox.multisel = 2;
    c->listbox.ncols = 3;
    c->listbox.percentages = snewn(3, int);
    c->listbox.percentages[0] = 25;
    c->listbox.percentages[1] = 10;
    c->listbox.percentages[2] = 65;

    char *title = dupcat(appname, " Event Log");
    PTDialog *d = simple_dialog(b, title, 720, es);
    sfree(title);
    d.onFinish = ^{
        es->dialog = NULL;
        es->listctrl = NULL;
    };
    es->dialog = (__bridge void *)d;

    place_window(d.window, (__bridge NSWindow *)parentwin);
    [d.window makeKeyAndOrderFront:nil];
}

eventlog_stuff *eventlogstuff_new(void)
{
    eventlog_stuff *es = snew(eventlog_stuff);
    memset(es, 0, sizeof(*es));
    es->seldata = strbuf_new();
    return es;
}

void eventlogstuff_free(eventlog_stuff *es)
{
    if (es->dialog)
        [(__bridge PTDialog *)es->dialog abandon];

    if (es->events_initial) {
        for (int i = 0; i < LOGEVENT_INITIAL_MAX; i++)
            sfree(es->events_initial[i]);
        sfree(es->events_initial);
    }
    if (es->events_circular) {
        for (int i = 0; i < LOGEVENT_CIRCULAR_MAX; i++)
            sfree(es->events_circular[i]);
        sfree(es->events_circular);
    }
    strbuf_free(es->seldata);

    sfree(es);
}

void logevent_dlg(eventlog_stuff *es, const char *string)
{
    char timebuf[40];
    struct tm tm;
    char **location;

    if (es->ninitial == 0) {
        es->events_initial = sresize(es->events_initial,
                                     LOGEVENT_INITIAL_MAX, char *);
        for (int i = 0; i < LOGEVENT_INITIAL_MAX; i++)
            es->events_initial[i] = NULL;
        es->events_circular = sresize(es->events_circular,
                                      LOGEVENT_CIRCULAR_MAX, char *);
        for (int i = 0; i < LOGEVENT_CIRCULAR_MAX; i++)
            es->events_circular[i] = NULL;
    }

    if (es->ninitial < LOGEVENT_INITIAL_MAX)
        location = &es->events_initial[es->ninitial];
    else
        location = &es->events_circular[(es->circular_first + es->ncircular)
                                        % LOGEVENT_CIRCULAR_MAX];

    tm = ltime();
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S\t", &tm);

    sfree(*location);
    *location = dupcat(timebuf, string);
    if (es->dialog && es->listctrl) {
        PTDialog *d = (__bridge PTDialog *)es->dialog;
        if (!d.ended)
            dlg_listbox_add(es->listctrl, &d->dp, *location);
    }
    if (es->ninitial < LOGEVENT_INITIAL_MAX) {
        es->ninitial++;
    } else if (es->ncircular < LOGEVENT_CIRCULAR_MAX) {
        es->ncircular++;
    } else if (es->ncircular == LOGEVENT_CIRCULAR_MAX) {
        es->circular_first = (es->circular_first + 1) % LOGEVENT_CIRCULAR_MAX;
        sfree(es->events_circular[es->circular_first]);
        es->events_circular[es->circular_first] = dupstr("..");
    }
}

/* ----------------------------------------------------------------------
 * The host CA and SSHFP configuration boxes, and importing settings.
 */

static void *cacfg;                    /* the open CA box, if any */

void show_ca_config_box(dlgparam *dp)
{
    if (cacfg) {
        [((__bridge PTDialog *)cacfg).window makeKeyAndOrderFront:nil];
        return;
    }

    struct controlbox *b = ctrl_new_box();
    setup_ca_config_box(b);
    PTDialog *d = simple_dialog(
        b, "PuTTY trusted host certification authorities", 560, NULL);
    d.onFinish = ^{
        cacfg = NULL;
    };
    cacfg = (__bridge void *)d;

    place_window(d.window, dp ? DLG(dp).window : nil);
    focus_first_control(d, b);
    [d.window makeKeyAndOrderFront:nil];
}

void show_sshfp_config_box(dlgparam *parent, Conf *conf)
{
    /*
     * The controls in this box edit the Conf of the configuration box
     * that opened it, so it's a sheet on that box: the user can't
     * close it (and free the Conf) while this is still up.
     */
    struct controlbox *b = ctrl_new_box();
    setup_sshfp_config_box(b);
    PTDialog *d = simple_dialog(b, "PuTTY DNS SSHFP settings", 480, conf);

    NSWindow *pw = parent ? DLG(parent).window : nil;
    if (pw && pw.isVisible) {
        d.sheetParent = pw;
        [pw beginSheet:d.window completionHandler:nil];
    } else {
        [d.window center];
        [d.window makeKeyAndOrderFront:nil];
    }
    focus_first_control(d, b);
}

void dlg_import_file_prompt(dlgparam *dp, dlg_import_done_fn done, void *ctx)
{
    PTDialog *d = DLG(dp);
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseFiles = YES;
    op.canChooseDirectories = NO;
    op.allowsMultipleSelection = NO;
    op.message = @"Import PuTTY settings from a registry export (.reg file)";
    [op beginSheetModalForWindow:d.window
               completionHandler:^(NSModalResponse resp) {
        if (resp != NSModalResponseOK || !op.URL || d.ended)
            return;
        Filename *fn = filename_from_str(op.URL.fileSystemRepresentation);
        done(&d->dp, fn, ctx);
        filename_free(fn);
    }];
}

void dlg_import_report(dlgparam *dp, const char *msg, bool success)
{
    static const char *const ok[] = { "OK" };
    message_box_general(DLG(dp).window,
                        success ? "PuTTY: import complete" :
                        "PuTTY: import finished with problems",
                        NULL, !success, ok, 1, NULL, NULL,
                        text_accessory(msg, false, 420, 260));
}
