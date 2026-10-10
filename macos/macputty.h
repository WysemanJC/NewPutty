/*
 * macputty.h: interfaces shared between the modules of the native
 * macOS (Cocoa) front end.
 *
 * Everything declared here is plain C, so that it can be included
 * from both the .c and .m files in this directory. Objective-C types
 * are passed around as 'void *' (bridged where they are used).
 */

#ifndef PUTTY_MACOS_MACPUTTY_H
#define PUTTY_MACOS_MACPUTTY_H

/* eventloop.c */
void macos_eventloop_setup(void);

/* main.m */
void macos_new_session_dialog(void);      /* New Session... */
void macos_open_session(Conf *conf);      /* takes ownership of conf */
void macos_launch_saved_session(const char *name);
void macos_session_closed(void);

/* window.m */
typedef struct MacFrontend MacFrontend;
MacFrontend *macos_frontend_new(Conf *conf);   /* takes ownership of conf */
void *macos_frontend_window(MacFrontend *fe);  /* its NSWindow, or NULL */
Seat *macos_frontend_seat(MacFrontend *fe);
void *macos_seat_window(Seat *seat);          /* NSWindow, or NULL */
FontSpec *macos_default_fontspec(void);
/* true if any session window would warn before closing */
bool macos_any_session_wants_quit_confirmation(void);

/* dialog.m */
typedef void (*macos_dialog_done_fn)(void *ctx, int result);

/*
 * The configuration box, used both before a session starts and
 * mid-session (Change Settings). 'after' is called with the result:
 * positive to go ahead, 0 for cancel.
 */
void macos_config_box(const char *title, Conf *conf, bool midsession,
                      int protcfginfo, void *parentwin,
                      macos_dialog_done_fn after, void *afterctx);
void macos_about_box(void *parentwin);

/*
 * A simple message box: an alert with the given buttons, run as a
 * sheet on 'parentwin' if that is non-NULL and otherwise as a free
 * window. 'after' gets the index (0-based, in the order given) of the
 * button that was pressed, or -1 if the box was dismissed without an
 * answer because its parent went away.
 */
void *macos_message_box(void *parentwin, const char *title,
                        const char *msg, bool critical,
                        const char *const *buttons, int nbuttons,
                        macos_dialog_done_fn after, void *afterctx);
void macos_cancel_message_box(void *box);

/* The Event Log functions (eventlogstuff_new etc) are declared in
 * unix/platform.h, and implemented in dialog.m. */

/* Seat dialogs (implemented in dialog.m) */
SeatPromptResult macos_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
SeatPromptResult macos_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
SeatPromptResult macos_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
const SeatDialogPromptDescriptions *macos_seat_prompt_descriptions(
    Seat *seat);
int macos_askappend(Seat *seat, Filename *filename,
                    void (*callback)(void *ctx, int result), void *ctx);

/*
 * Dialogs started on behalf of a session (host key prompts and so on)
 * are tracked per session, so that they can be torn down if the
 * session window goes away first.
 */
void macos_frontend_register_dialog(Seat *seat, void *box);
void macos_frontend_unregister_dialog(Seat *seat, void *box);

/* config-macos.c */
struct controlbox;
void macos_setup_config_box(struct controlbox *b, bool midsession);

#endif /* PUTTY_MACOS_MACPUTTY_H */
