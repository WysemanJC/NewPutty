/*
 * eventloop.c: hooking PuTTY's event model (uxsel file descriptor
 * watches, timers and toplevel callbacks) into the Cocoa run loop.
 *
 * File descriptors are watched by a helper thread that sits in
 * poll(). When poll() returns, the thread signals a run loop source
 * on the main thread and waits; the main thread delivers the events
 * to uxsel, rebuilds the set of fds, and hands it back. All of
 * PuTTY's own code therefore runs on the main thread, exactly as it
 * does under GTK.
 *
 * The run loop sources and the timer are added in the common modes,
 * so sessions keep running while a menu is open, a window is being
 * resized or a modal dialog is up.
 */

#include <CoreFoundation/CoreFoundation.h>

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include "putty.h"
#include "macputty.h"

struct uxsel_id {
    int fd;
};

static CFRunLoopRef main_runloop;
static CFRunLoopSourceRef fd_source, callback_source;
static CFRunLoopTimerRef timer;
static unsigned long timer_next;

/*
 * State shared with the poll thread, protected by poll_mutex. The
 * pollfd array belongs to the main thread while the state is
 * POLL_IDLE, and to the poll thread while it is POLL_RUNNING.
 */
static pthread_mutex_t poll_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t poll_cond = PTHREAD_COND_INITIALIZER;
static enum { POLL_IDLE, POLL_RUNNING, POLL_DONE } poll_state = POLL_IDLE;
static struct pollfd *pollfds;
static size_t npollfds, pollfdsize;
static int wake_pipe[2] = { -1, -1 };

/* Main thread only. */
static bool fdset_dirty;          /* uxsel's set changed since submission */
static bool woken_poller;         /* we've already poked the poll thread */

/*
 * Fds that were removed from uxsel since the current poll was
 * submitted (see deliver_results).
 */
static int *suspect_fds;
static size_t nsuspect, suspectsize;

static void signal_source(CFRunLoopSourceRef src)
{
    CFRunLoopSourceSignal(src);
    CFRunLoopWakeUp(main_runloop);
}

static bool is_suspect(int fd)
{
    for (size_t i = 0; i < nsuspect; i++)
        if (suspect_fds[i] == fd)
            return true;
    return false;
}

uxsel_id *uxsel_input_add(int fd, int rwx)
{
    uxsel_id *id = snew(uxsel_id);
    id->fd = fd;
    fdset_dirty = true;
    signal_source(fd_source);
    return id;
}

void uxsel_input_remove(uxsel_id *id)
{
    sgrowarray(suspect_fds, suspectsize, nsuspect);
    suspect_fds[nsuspect++] = id->fd;
    sfree(id);
    fdset_dirty = true;
    signal_source(fd_source);
}

/* Look up the events uxsel currently wants for an fd (0 if none). */
static int current_rwx(int fd)
{
    int state, rwx;
    for (int f = first_fd(&state, &rwx); f >= 0; f = next_fd(&state, &rwx))
        if (f == fd)
            return rwx;
    return 0;
}

static void *poll_thread(void *arg)
{
    /* Signals are for the main thread. */
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);

    pthread_mutex_lock(&poll_mutex);
    while (true) {
        while (poll_state != POLL_RUNNING)
            pthread_cond_wait(&poll_cond, &poll_mutex);
        struct pollfd *fds = pollfds;
        nfds_t nfds = npollfds;
        pthread_mutex_unlock(&poll_mutex);

        int ret;
        do {
            ret = poll(fds, nfds, -1);
        } while (ret < 0 && errno == EINTR);

        pthread_mutex_lock(&poll_mutex);
        poll_state = POLL_DONE;
        signal_source(fd_source);
    }
    return NULL;
}

static void submit_poll(void)
{
    int state, rwx;

    npollfds = 0;
    sgrowarray(pollfds, pollfdsize, npollfds);
    pollfds[npollfds].fd = wake_pipe[0];
    pollfds[npollfds].events = POLLIN;
    pollfds[npollfds].revents = 0;
    npollfds++;

    for (int fd = first_fd(&state, &rwx); fd >= 0;
         fd = next_fd(&state, &rwx)) {
        short events = 0;
        if (rwx & SELECT_R)
            events |= POLLIN;
        if (rwx & SELECT_W)
            events |= POLLOUT;
        if (rwx & SELECT_X)
            events |= POLLPRI;
        sgrowarray(pollfds, pollfdsize, npollfds);
        pollfds[npollfds].fd = fd;
        pollfds[npollfds].events = events;
        pollfds[npollfds].revents = 0;
        npollfds++;
    }

    fdset_dirty = false;
    woken_poller = false;
    nsuspect = 0;

    pthread_mutex_lock(&poll_mutex);
    poll_state = POLL_RUNNING;
    pthread_cond_signal(&poll_cond);
    pthread_mutex_unlock(&poll_mutex);
}

static void deliver_results(void)
{
    char buf[64];
    while (read(wake_pipe[0], buf, sizeof(buf)) > 0)
        ;                              /* drain the wakeup pipe */

    /*
     * Results are only delivered for events the fd is still waiting
     * for. If the set of fds changed while poll() was running, an fd
     * number may by now belong to a different file. A spurious
     * readability report is harmless (every reader copes with
     * EWOULDBLOCK), but a spurious writability report would make a
     * socket that is still connecting look connected. So writability
     * and exceptional reports for an fd that was removed in the
     * meantime are thrown away. poll is level-triggered, so anything
     * real will be reported again next time round.
     */
    for (size_t i = 1; i < npollfds; i++) {
        int fd = pollfds[i].fd;
        short rev = pollfds[i].revents;
        if (!rev || (rev & POLLNVAL))
            continue;

        /*
         * Process exceptional notifications before ordinary
         * readability ones, or we may go straight past the urgent
         * marker. An error or hangup is reported as readability and
         * writability, so whichever the fd is waiting for finds out.
         */
        if ((rev & POLLPRI) && !is_suspect(fd) &&
            (current_rwx(fd) & SELECT_X))
            select_result(fd, SELECT_X);
        if ((rev & (POLLIN | POLLHUP | POLLERR)) &&
            (current_rwx(fd) & SELECT_R))
            select_result(fd, SELECT_R);
        if ((rev & (POLLOUT | POLLERR | POLLHUP)) && !is_suspect(fd) &&
            (current_rwx(fd) & SELECT_W))
            select_result(fd, SELECT_W);
    }

    run_toplevel_callbacks();
}

static void fd_source_perform(void *info)
{
    pthread_mutex_lock(&poll_mutex);
    int state = poll_state;
    if (state == POLL_DONE)
        poll_state = POLL_IDLE;
    pthread_mutex_unlock(&poll_mutex);

    if (state == POLL_DONE) {
        deliver_results();
        submit_poll();
    } else if (state == POLL_IDLE) {
        submit_poll();
    } else if (fdset_dirty && !woken_poller) {
        /*
         * poll() is running on an out-of-date set of fds. Wake it up;
         * when it returns we'll hand it the new set.
         */
        woken_poller = true;
        if (write(wake_pipe[1], "", 1) < 0) {
            /* the pipe is full, so the poll thread is waking anyway */
        }
    }
}

/* ----------------------------------------------------------------------
 * Timers.
 */

static void timer_fired(CFRunLoopTimerRef t, void *info)
{
    unsigned long now = timer_next, next;

    if (timer) {
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
        timer = NULL;
    }

    /*
     * run_timers() may call timer_change_notify, which sets up a new
     * timer itself. If it doesn't, and there is still timing to do,
     * we schedule it ourselves.
     */
    if (run_timers(now, &next) && !timer)
        timer_change_notify(next);

    run_toplevel_callbacks();
}

void timer_change_notify(unsigned long next)
{
    if (timer) {
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
        timer = NULL;
    }

    long ticks = next - GETTICKCOUNT();
    if (ticks <= 0)
        ticks = 1;                     /* just in case */

    timer_next = next;
    timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + ticks / (double)TICKSPERSEC,
        0, 0, 0, timer_fired, NULL);
    CFRunLoopAddTimer(main_runloop, timer, kCFRunLoopCommonModes);
}

/* ----------------------------------------------------------------------
 * Toplevel callbacks.
 */

static void callback_source_perform(void *info)
{
    run_toplevel_callbacks();
    if (toplevel_callback_pending())
        signal_source(callback_source);
}

static void notify_toplevel_callback(void *ctx)
{
    signal_source(callback_source);
}

/* ----------------------------------------------------------------------
 * Setup. Must be called on the main thread before anything uses
 * uxsel, timers or callbacks.
 */

void macos_eventloop_setup(void)
{
    main_runloop = CFRunLoopGetMain();

    /* Writing to a closed socket must not kill the whole app. */
    signal(SIGPIPE, SIG_IGN);

    uxsel_init();

    if (pipe(wake_pipe) < 0)
        modalfatalbox("Unable to create a pipe: %s", strerror(errno));
    nonblock(wake_pipe[0]);
    nonblock(wake_pipe[1]);
    cloexec(wake_pipe[0]);
    cloexec(wake_pipe[1]);

    CFRunLoopSourceContext fdctx = {
        .version = 0, .perform = fd_source_perform,
    };
    fd_source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &fdctx);
    CFRunLoopAddSource(main_runloop, fd_source, kCFRunLoopCommonModes);

    CFRunLoopSourceContext cbctx = {
        .version = 0, .perform = callback_source_perform,
    };
    callback_source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &cbctx);
    CFRunLoopAddSource(main_runloop, callback_source, kCFRunLoopCommonModes);

    request_callback_notifications(notify_toplevel_callback, NULL);

    pthread_attr_t attr;
    pthread_t thread;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, poll_thread, NULL) != 0)
        modalfatalbox("Unable to start the network thread");
    pthread_attr_destroy(&attr);

    /* Hand the poll thread its first (empty) set of fds. */
    signal_source(fd_source);
}
