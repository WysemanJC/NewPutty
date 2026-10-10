/*
 * config-macos.c: the macOS-specific parts of the PuTTY configuration
 * box.
 */

#include <assert.h>
#include <stdlib.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"
#include "macputty.h"

static void about_handler(dlgcontrol *ctrl, dlgparam *dlg,
                          void *data, int event)
{
    if (event == EVENT_ACTION)
        macos_about_box(NULL);
}

void macos_setup_config_box(struct controlbox *b, bool midsession)
{
    struct controlset *s;
    dlgcontrol *c;

    if (!midsession) {
        /*
         * Add the About button to the standard panel.
         */
        s = ctrl_getset(b, "", "", "");
        c = ctrl_pushbutton(s, "About", 'a', HELPCTX(no_help),
                            about_handler, P(NULL));
        c->column = 0;
    }

    /*
     * The scrollbar can go on either side of the window.
     */
    s = ctrl_getset(b, "Window", "scrollback",
                    "Control the scrollback in the window");
    ctrl_checkbox(s, "Scrollbar on left", 'l',
                  HELPCTX(no_help),
                  conf_checkbox_handler,
                  I(CONF_scrollbar_on_left));
    /*
     * Really this wants to go just after `Display scrollbar'. See
     * if we can find that control, and do some shuffling.
     */
    for (size_t i = 0; i < s->ncontrols; i++) {
        c = s->ctrls[i];
        if (c->type == CTRL_CHECKBOX &&
            c->context.i == CONF_scrollbar) {
            if (i < s->ncontrols-2) {
                c = s->ctrls[s->ncontrols-1];
                memmove(s->ctrls+i+2, s->ctrls+i+1,
                        (s->ncontrols-i-2)*sizeof(dlgcontrol *));
                s->ctrls[i+1] = c;
            }
            break;
        }
    }

    /*
     * On a Mac keyboard there are two reasonable candidates for the
     * Meta key, and people have strong opinions about which (if
     * either) should keep its normal function.
     */
    s = ctrl_getset(b, "Terminal/Keyboard", "meta",
                    "Choose the Meta key:");
    ctrl_checkbox(s, "Option key acts as Meta", 'p',
                  HELPCTX(no_help),
                  conf_checkbox_handler, I(CONF_osx_option_meta));
    ctrl_checkbox(s, "Command key acts as Meta", 'm',
                  HELPCTX(no_help),
                  conf_checkbox_handler, I(CONF_osx_command_meta));
}
