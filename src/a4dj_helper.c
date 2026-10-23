/*
 * a4dj_helper - background service that owns the Native Instruments Audio 4 DJ
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The device protocol (command channel, audio parameters, stream layout, check bytes, the rule
 * that every input packet is answered by an output packet of the same length) comes from the
 * open-source Linux driver snd-usb-caiaq by Daniel Mack and others (GPL), so this file is GPL too.
 *
 * It runs as a launchd daemon. It streams audio to and from the USB device, keeps that audio in
 * shared memory, and hands the Core Audio driver a handle to that memory over XPC.
 */

#ifndef __APPLE__
#define _POSIX_C_SOURCE 200809L
#endif
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <libusb.h>
#include <mach/mach_time.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread/qos.h>
#endif

#include "a4dj_shared.h"

#ifndef A4DJ_NO_XPC
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#endif

#define A4_VID 0x17CC
#define A4_PID 0x0839
#define EP_CMD_OUT 0x01
#define EP_CMD_IN 0x81
#define EP_ISO_IN 0x82
#define EP_ISO_OUT 0x06
#define CMD_GET_DEVICE_INFO 0x01
#define CMD_AUDIO_PARAMS 0x09

#define N_STREAMS 2
#define ROW_BYTES (N_STREAMS * 4)
#define FRAME_BYTES (2 * ROW_BYTES)
#define PKT_BYTES 160
#define PKTS 8
#define IN_PKT_LEN 512
#define N_IN 16
#define N_OUT 32

static void logf_(const char *fmt, ...)
{
    char ts[32];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    fprintf(stderr, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

/* ------------------------------------------------------------------ core */

typedef struct {
    uint64_t rows_checked, check_bad, bit7;
    uint64_t in_resubmit_fail;
    uint64_t in_packets, in_data_packets, in_bad_status;
    uint64_t out_ok, out_fail, out_cb_err, out_no_slot;
    int out_fail_code;
} Stats;

static int32_t s24(uint8_t b0, uint8_t b1, uint8_t b2)
{
    int32_t v = ((int32_t)b0 << 16) | ((int32_t)b1 << 8) | (int32_t)b2;
    if (v & 0x800000)
        v -= 1 << 24;
    return v;
}

/*
 * Input packet, per row of 8 bytes (two streams): check byte for each stream, then the high byte of
 * each stream, the middle byte, the low byte. Rows alternate; odd rows are the physical left channel
 * and even rows the right (measured on the hardware). Channel numbering: 0 = in1 L, 1 = in1 R,
 * 2 = in2 L, 3 = in2 R.
 */
static void decode_in_packet(const uint8_t *p, int len, A4DJShared *shm, uint64_t first_frame, Stats *st)
{
    int rows = len / ROW_BYTES;
    for (int r = 0; r < rows; r++) {
        const uint8_t *row = p + r * ROW_BYTES;
        int side = r & 1;
        uint64_t f = first_frame + (uint64_t)(r >> 1);
        float *frame = &shm->in_ring[(f % A4DJ_RING_FRAMES) * A4DJ_CHANNELS];
        for (int s = 0; s < N_STREAMS; s++) {
            uint8_t chk = row[s];
            st->rows_checked++;
            if ((chk & 0x3F) != (uint8_t)((s << 1) | ((~r) & 1)))
                st->check_bad++;
            if (chk & 0x80)
                st->bit7++;
            int32_t v = s24(row[N_STREAMS + s], row[2 * N_STREAMS + s], row[3 * N_STREAMS + s]);
            frame[2 * s + (side ^ 1)] = (float)v / 8388608.0f;
        }
    }
}

/* Same rule as the standalone test: a multiple of 8 packets per transfer, never ending on an empty one. */
static int justify_lengths(const unsigned in[PKTS], unsigned out[PKTS])
{
    int trailing = 0;
    while (trailing < PKTS && in[PKTS - 1 - trailing] == 0)
        trailing++;
    if (trailing == PKTS)
        return 0;
    for (int i = 0; i < trailing; i++)
        out[i] = 0;
    for (int i = 0; i < PKTS - trailing; i++)
        out[trailing + i] = in[i];
    return 1;
}

/*
 * Output audio, one frame at a time from out_ring, turned into the byte stream the device expects. Each
 * stream's bytes start 2 bytes before its first real sample (the Linux driver starts each stream 4 bytes
 * into its audio, which makes the device's first full sample the second one), so the pipe starts holding
 * two filler bytes. Rows take 3 bytes from each stream at a time.
 */
typedef struct {
    uint8_t q[N_STREAMS][24];
    int count; /* bytes held per stream (the streams stay in step) */
    int64_t next;
    A4DJShared *shm;
} OutPipe;

/*
 * The helper plays frame N when frame N + OUT_DELAY_FRAMES has just arrived. That keeps playback a safe distance
 * behind what the driver has already written, however much the arrival times wander.
 */
#define OUT_DELAY_FRAMES 512

static void pipe_publish(OutPipe *p)
{
    __atomic_store_n(&p->shm->out_next, p->next > 0 ? (uint64_t)p->next : 0, __ATOMIC_RELEASE);
}

static void pipe_init(OutPipe *p, A4DJShared *shm, uint64_t start)
{
    memset(p, 0, sizeof *p);
    p->shm = shm;
    p->count = 2;
    p->next = (int64_t)start - OUT_DELAY_FRAMES;
    pipe_publish(p);
}

static void put_sample(uint8_t *dst, float x)
{
    if (!(x == x))
        x = 0.0f;
    if (x > 1.0f)
        x = 1.0f;
    if (x < -1.0f)
        x = -1.0f;
    long v = lrintf(x * 8388607.0f);
    dst[0] = (uint8_t)((v >> 16) & 0xFF);
    dst[1] = (uint8_t)((v >> 8) & 0xFF);
    dst[2] = (uint8_t)(v & 0xFF);
}

static void pipe_refill(OutPipe *p)
{
    float silence[A4DJ_CHANNELS] = {0, 0, 0, 0};
    float *slot = silence;
    if (p->next >= 0)
        slot = &p->shm->out_ring[((uint64_t)p->next % A4DJ_RING_FRAMES) * A4DJ_CHANNELS];
    for (int s = 0; s < N_STREAMS; s++) {
        put_sample(&p->q[s][p->count], slot[2 * s]);
        put_sample(&p->q[s][p->count + 3], slot[2 * s + 1]);
    }
    p->count += 6;
    if (p->next >= 0)
        memset(slot, 0, A4DJ_CHANNELS * sizeof(float)); /* consumed: leave silence behind */
    p->next++;
    pipe_publish(p);
}

static void pipe_take3(OutPipe *p, uint8_t t0[3], uint8_t t1[3])
{
    while (p->count < 3)
        pipe_refill(p);
    memcpy(t0, p->q[0], 3);
    memcpy(t1, p->q[1], 3);
    p->count -= 3;
    memmove(p->q[0], p->q[0] + 3, (size_t)p->count);
    memmove(p->q[1], p->q[1] + 3, (size_t)p->count);
}

/*
 * Output packet, per row of 8 bytes: first and second sample bytes of both streams, then the two
 * check bytes (stream << 1 | parity, parity alternating per row and starting at 1 in every packet),
 * then the third sample byte of both streams.
 */
static int fill_out_packet(uint8_t *buf, int len, OutPipe *pipe)
{
    if (len <= 0 || len % ROW_BYTES)
        return -1;
    for (int p = 0; p < len / ROW_BYTES; p++) {
        uint8_t t0[3], t1[3];
        pipe_take3(pipe, t0, t1);
        uint8_t par = (p % 2 == 0) ? 1 : 0;
        uint8_t *b = buf + p * ROW_BYTES;
        b[0] = t0[0];
        b[1] = t1[0];
        b[2] = t0[1];
        b[3] = t1[1];
        b[4] = (uint8_t)((0 << 1) | par);
        b[5] = (uint8_t)((1 << 1) | par);
        b[6] = t0[2];
        b[7] = t1[2];
    }
    return 0;
}

/* ------------------------------------------------------------------ engine */

struct Engine;
typedef struct {
    struct Engine *e;
    int idx;
} Slot;

typedef struct Engine {
    A4DJShared *shm;
    libusb_context *ctx;
    libusb_device_handle *h;
    struct libusb_transfer *in_t[N_IN];
    struct libusb_transfer *out_t[N_OUT];
    unsigned char *in_buf[N_IN];
    unsigned char *out_buf[N_OUT];
    Slot in_slot[N_IN], out_slot[N_OUT];
    int out_busy[N_OUT];
    volatile int running, failed;
    int in_dead[N_IN]; /* input transfers that could not be resubmitted yet; retried from the main loop */
    int pending;
    uint64_t f_in;
    int pipe_started;
    OutPipe pipe;
    double tpf;        /* nominal host ticks per frame */
    double base_host;  /* the clock is a straight line: host time = base_host + (frame - base_frame) * rate */
    uint64_t base_frame;
    double rate;       /* host ticks per frame, nudged slightly to follow the box's real speed */
    int model_set, locked, win_n;
    double win_min;
    double last_data;
    double late_max, early_max; /* how far input batches strayed from that smooth clock, in frames, since the last report */
    Stats st;
} Engine;

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void LIBUSB_CALL out_cb(struct libusb_transfer *t)
{
    Slot *s = (Slot *)t->user_data;
    Engine *e = s->e;
    e->pending--;
    e->out_busy[s->idx] = 0;
    if (t->status != LIBUSB_TRANSFER_COMPLETED && t->status != LIBUSB_TRANSFER_CANCELLED)
        e->st.out_cb_err++;
}

static void send_reply(Engine *e, const unsigned lens[PKTS])
{
    unsigned shifted[PKTS];
    if (!justify_lengths(lens, shifted))
        return;
    int idx = -1;
    for (int i = 0; i < N_OUT; i++) {
        if (!e->out_busy[i]) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        e->st.out_no_slot++;
        return;
    }
    struct libusb_transfer *t = e->out_t[idx];
    unsigned total = 0;
    for (int i = 0; i < PKTS; i++) {
        if (shifted[i]) {
            fill_out_packet(e->out_buf[idx] + total, (int)shifted[i], &e->pipe);
            total += shifted[i];
        }
    }
    libusb_fill_iso_transfer(t, e->h, EP_ISO_OUT, e->out_buf[idx], (int)total, PKTS, out_cb, &e->out_slot[idx], 0);
    for (int i = 0; i < PKTS; i++)
        t->iso_packet_desc[i].length = shifted[i];
    int r = libusb_submit_transfer(t);
    if (r == 0) {
        e->out_busy[idx] = 1;
        e->pending++;
        e->st.out_ok++;
    } else {
        e->st.out_fail++;
        e->st.out_fail_code = r;
    }
}

/*
 * Publishes the stream's clock: "frame N happened at host time H". Batches of audio arrive a little earlier or
 * later than the true rate, so each arrival is only used to nudge a smooth model (a first-order filter with a
 * time constant of about half a second) instead of being published directly. Core Audio schedules from this
 * clock, so it must not wobble.
 */
static void publish_clock(Engine *e)
{
    double now = (double)mach_absolute_time();
    if (!e->model_set) {
        e->base_host = now;
        e->base_frame = e->f_in;
        e->rate = e->tpf;
        e->win_min = 1e18;
        e->win_n = 0;
        e->model_set = 1;
    }
    double pred = e->base_host + (double)(e->f_in - e->base_frame) * e->rate;
    double err = (now - pred) / e->tpf; /* in frames: positive = this batch is later than the clock says */
    if (err > e->late_max)
        e->late_max = err;
    if (-err > e->early_max)
        e->early_max = -err;
    if (err < e->win_min)
        e->win_min = err;
    e->win_n++;

    if (!e->locked) {
        /* first second: put the line through the earliest arrivals, then start publishing */
        if (e->win_n >= 1000) {
            e->base_host = pred + e->win_min * e->tpf;
            e->base_frame = e->f_in;
            e->locked = 1;
            e->win_n = 0;
            e->win_min = 1e18;
        }
    } else if (e->win_n >= 500) {
        /* every half second: arrivals are late by a varying amount but never early by much, so the earliest
         * arrival in the window shows whether the line is ahead of or behind the box. Correct it by changing
         * the line's rate a little (at most 200 ppm), never by jumping it, so Core Audio sees a steady clock. */
        e->base_host = pred;
        e->base_frame = e->f_in;
        double adj = e->win_min / (4.0 * A4DJ_RATE);
        if (adj > 200e-6)
            adj = 200e-6;
        if (adj < -200e-6)
            adj = -200e-6;
        e->rate = e->tpf * (1.0 + adj);
        e->win_n = 0;
        e->win_min = 1e18;
    }
    double h = e->base_host + (double)(e->f_in - e->base_frame) * e->rate;
    a4dj_clock_write2(e->shm, e->f_in, (uint64_t)h, e->rate);
}

static void LIBUSB_CALL in_cb(struct libusb_transfer *t)
{
    Slot *s = (Slot *)t->user_data;
    Engine *e = s->e;
    if (!e->running || t->status == LIBUSB_TRANSFER_CANCELLED) {
        e->pending--;
        return;
    }
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) {
        logf_("device lost (the USB transfer reported NO_DEVICE)");
        e->failed = 1;
        e->pending--;
        return;
    }
    unsigned lens[PKTS];
    int any = 0, have_first = 0;
    uint64_t first_start = 0;
    for (int i = 0; i < PKTS; i++) {
        struct libusb_iso_packet_descriptor *d = &t->iso_packet_desc[i];
        lens[i] = 0;
        e->st.in_packets++;
        if (d->status != LIBUSB_TRANSFER_COMPLETED) {
            e->st.in_bad_status++;
            continue;
        }
        if (d->actual_length > 0 && d->actual_length % FRAME_BYTES == 0 && d->actual_length <= PKT_BYTES) {
            unsigned char *p = libusb_get_iso_packet_buffer_simple(t, (unsigned)i);
            lens[i] = d->actual_length;
            any = 1;
            e->st.in_data_packets++;
            if (!have_first) {
                first_start = e->f_in;
                have_first = 1;
            }
            decode_in_packet(p, (int)d->actual_length, e->shm, e->f_in, &e->st);
            e->f_in += d->actual_length / FRAME_BYTES;
        }
    }
    if (any) {
        __atomic_store_n(&e->shm->in_frames, e->f_in, __ATOMIC_RELEASE);
        publish_clock(e);
        if (!e->pipe_started) {
            pipe_init(&e->pipe, e->shm, first_start);
            e->pipe_started = 1;
            logf_("audio is flowing; settling the clock for a second");
        }
        if (e->locked && !__atomic_load_n(&e->shm->streaming, __ATOMIC_RELAXED)) {
            __atomic_store_n(&e->shm->streaming, 1, __ATOMIC_RELEASE);
            logf_("clock settled, audio available to the driver");
        }
        send_reply(e, lens);
        e->last_data = now_seconds();
    }
    libusb_set_iso_packet_lengths(t, IN_PKT_LEN);
    int r = libusb_submit_transfer(t);
    if (r != 0) {
        e->pending--;
        e->st.in_resubmit_fail++;
        if (r == LIBUSB_ERROR_NO_DEVICE) {
            logf_("device lost (resubmit: %s)", libusb_error_name(r));
            e->failed = 1;
        } else {
            e->in_dead[s->idx] = 1; /* try again shortly instead of giving up on the whole stream */
        }
    }
}

static int bulk_out(Engine *e, unsigned char *data, int len)
{
    int n = 0;
    return libusb_bulk_transfer(e->h, EP_CMD_OUT, data, len, &n, 200);
}

static int bulk_reply(Engine *e, unsigned char want, unsigned char *buf, int *got)
{
    for (int tries = 0; tries < 10; tries++) {
        int n = 0;
        int r = libusb_bulk_transfer(e->h, EP_CMD_IN, buf, 64, &n, 1000);
        if (r != 0)
            return r;
        if (n > 0 && buf[0] == want) {
            *got = n;
            return 0;
        }
    }
    return LIBUSB_ERROR_TIMEOUT;
}

static int device_start(Engine *e)
{
    int cfg = 0;
    if (libusb_get_configuration(e->h, &cfg) != 0 || cfg != 1)
        libusb_set_configuration(e->h, 1);
    int r = libusb_claim_interface(e->h, 0);
    if (r != 0) {
        logf_("claim interface failed: %s", libusb_error_name(r));
        return -1;
    }
    r = libusb_set_interface_alt_setting(e->h, 0, 1);
    if (r != 0) {
        logf_("set alt setting failed: %s", libusb_error_name(r));
        return -1;
    }
    unsigned char buf[64];
    int n = 0;
    while (libusb_bulk_transfer(e->h, EP_CMD_IN, buf, 64, &n, 50) == 0) { /* drain */
    }
    unsigned char cmd = CMD_GET_DEVICE_INFO;
    if (bulk_out(e, &cmd, 1) != 0 || bulk_reply(e, CMD_GET_DEVICE_INFO, buf, &n) != 0 || n < 15) {
        logf_("no device info reply");
        return -1;
    }
    if (buf[14] != 2) {
        logf_("unexpected data alignment %d", buf[14]);
        return -1;
    }
    unsigned char params[6] = {CMD_AUDIO_PARAMS, 0, 2, PKT_BYTES & 0xFF, PKT_BYTES >> 8, 1};
    if (bulk_out(e, params, 6) != 0 || bulk_reply(e, CMD_AUDIO_PARAMS, buf, &n) != 0 || n < 2 || buf[1] != 1) {
        logf_("audio parameters not acknowledged");
        return -1;
    }
    return 0;
}

/* One streaming session: returns when the device goes away or stops delivering audio. */
static void run_session(A4DJShared *shm, double tpf)
{
    Engine *e = (Engine *)calloc(1, sizeof *e);
    if (!e)
        return;
    e->shm = shm;
    e->tpf = tpf;

    if (libusb_init(&e->ctx) != 0) {
        free(e);
        return;
    }
    e->h = libusb_open_device_with_vid_pid(e->ctx, A4_VID, A4_PID);
    if (!e->h) {
        libusb_exit(e->ctx);
        free(e);
        return;
    }
    logf_("Audio 4 DJ found");
    if (device_start(e) != 0) {
        libusb_close(e->h);
        libusb_exit(e->ctx);
        free(e);
        return;
    }

    /* a new stream means a new timeline */
    __atomic_store_n(&shm->streaming, 0, __ATOMIC_RELEASE);
    memset(shm->in_ring, 0, sizeof shm->in_ring);
    memset(shm->out_ring, 0, sizeof shm->out_ring);
    __atomic_store_n(&shm->in_frames, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&shm->out_next, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&shm->epoch, shm->epoch + 1, __ATOMIC_RELEASE);

    for (int i = 0; i < N_IN; i++) {
        e->in_buf[i] = (unsigned char *)calloc(PKTS, IN_PKT_LEN);
        e->in_t[i] = libusb_alloc_transfer(PKTS);
        e->in_slot[i].e = e;
        e->in_slot[i].idx = i;
    }
    for (int i = 0; i < N_OUT; i++) {
        e->out_buf[i] = (unsigned char *)calloc(PKTS, PKT_BYTES);
        e->out_t[i] = libusb_alloc_transfer(PKTS);
        e->out_slot[i].e = e;
        e->out_slot[i].idx = i;
    }

    e->running = 1;
    e->last_data = now_seconds();
    for (int i = 0; i < N_IN; i++) {
        libusb_fill_iso_transfer(e->in_t[i], e->h, EP_ISO_IN, e->in_buf[i], PKTS * IN_PKT_LEN, PKTS, in_cb, &e->in_slot[i], 0);
        libusb_set_iso_packet_lengths(e->in_t[i], IN_PKT_LEN);
        if (libusb_submit_transfer(e->in_t[i]) == 0)
            e->pending++;
    }

    double last_report = now_seconds();
    while (!e->failed && now_seconds() - e->last_data < 2.0) {
        struct timeval tv = {0, 100000};
        libusb_handle_events_timeout(e->ctx, &tv);
        for (int i = 0; i < N_IN; i++) {
            if (!e->in_dead[i])
                continue;
            libusb_set_iso_packet_lengths(e->in_t[i], IN_PKT_LEN);
            int rr = libusb_submit_transfer(e->in_t[i]);
            if (rr == 0) {
                e->in_dead[i] = 0;
                e->pending++;
            } else if (rr == LIBUSB_ERROR_NO_DEVICE) {
                logf_("device lost (retry: %s)", libusb_error_name(rr));
                e->failed = 1;
            }
        }
        if (now_seconds() - last_report >= 30.0) {
            last_report = now_seconds();
            Stats *st = &e->st;
            logf_("stats: in %llu out ok %llu refused %llu (%s) input resubmit failures %llu check errors %llu underrun flags %llu, input timing: up to %.0f frames late and %.0f early",
                  (unsigned long long)st->in_data_packets, (unsigned long long)st->out_ok, (unsigned long long)st->out_fail,
                  st->out_fail ? libusb_error_name(st->out_fail_code) : "none", (unsigned long long)st->in_resubmit_fail, (unsigned long long)st->check_bad,
                  (unsigned long long)st->bit7, e->late_max, e->early_max);
            e->late_max = 0;
            e->early_max = 0;
        }
    }
    logf_("stream stopped (%s)", e->failed ? "device error, see the line above" : "no audio for 2 s");

    __atomic_store_n(&shm->streaming, 0, __ATOMIC_RELEASE);
    e->running = 0;
    for (int i = 0; i < N_IN; i++)
        libusb_cancel_transfer(e->in_t[i]);
    for (int i = 0; i < N_OUT; i++)
        if (e->out_busy[i])
            libusb_cancel_transfer(e->out_t[i]);
    double settle = now_seconds();
    while (e->pending > 0 && now_seconds() - settle < 2.0) {
        struct timeval tv = {0, 50000};
        libusb_handle_events_timeout(e->ctx, &tv);
    }
    libusb_set_interface_alt_setting(e->h, 0, 0);
    libusb_release_interface(e->h, 0);
    if (e->pending == 0) {
        for (int i = 0; i < N_IN; i++) {
            libusb_free_transfer(e->in_t[i]);
            free(e->in_buf[i]);
        }
        for (int i = 0; i < N_OUT; i++) {
            libusb_free_transfer(e->out_t[i]);
            free(e->out_buf[i]);
        }
    }
    libusb_close(e->h);
    libusb_exit(e->ctx);
    if (e->pending == 0)
        free(e);
}

typedef struct {
    A4DJShared *shm;
    double tpf;
    int once;
} EngineArgs;

/*
 * Late delivery of input batches shows up as dropouts, so the thread that handles USB runs at the highest
 * interactive priority, and asks the scheduler for a real-time slot of about half a millisecond every
 * millisecond. QoS is set before libusb starts its own event thread, which inherits it.
 */
static void raise_priority(void)
{
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    double ticks_per_ms = 1e6 * (double)tb.denom / (double)tb.numer;
    thread_time_constraint_policy_data_t p;
    p.period = (uint32_t)(1.0 * ticks_per_ms);
    p.computation = (uint32_t)(0.5 * ticks_per_ms);
    p.constraint = (uint32_t)(0.9 * ticks_per_ms);
    p.preemptible = 1;
    kern_return_t kr = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    logf_("USB thread priority raised (real-time policy %s)", kr == KERN_SUCCESS ? "granted" : "refused");
#endif
}

static void *engine_thread(void *arg)
{
    EngineArgs *a = (EngineArgs *)arg;
    raise_priority();
    for (;;) {
        run_session(a->shm, a->tpf);
        if (a->once)
            return NULL;
        sleep(1); /* device not there, or it went away: look again in a second */
    }
}

static A4DJShared *shm_create(void)
{
    size_t len = (sizeof(A4DJShared) + 16383u) & ~(size_t)16383u;
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
    if (p == MAP_FAILED)
        return NULL;
    A4DJShared *s = (A4DJShared *)p;
    memset(s, 0, sizeof *s);
    s->magic = A4DJ_SHM_MAGIC;
    s->version = A4DJ_SHM_VERSION;
    s->epoch = (uint32_t)time(NULL);
    return s;
}

static double host_ticks_per_frame(void)
{
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    double ticks_per_second = 1e9 * (double)tb.denom / (double)tb.numer;
    return ticks_per_second / A4DJ_RATE;
}

#ifndef A4DJ_NO_MAIN
#ifndef A4DJ_NO_XPC

static A4DJShared *gShm;
static xpc_object_t gShmObject;

static void handle_peer(xpc_connection_t peer)
{
    xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY) {
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_value(reply, "shm", gShmObject);
                xpc_dictionary_set_int64(reply, "pid", (int64_t)getpid());
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }
        }
    });
    xpc_connection_resume(peer);
}

int main(void)
{
    gShm = shm_create();
    if (!gShm) {
        logf_("could not create shared memory");
        return 1;
    }
    size_t len = (sizeof(A4DJShared) + 16383u) & ~(size_t)16383u;
    gShmObject = xpc_shmem_create(gShm, len);
    if (!gShmObject) {
        logf_("could not wrap shared memory for XPC");
        return 1;
    }

    static EngineArgs args;
    args.shm = gShm;
    args.tpf = host_ticks_per_frame();
    args.once = 0;
    pthread_t th;
    pthread_create(&th, NULL, engine_thread, &args);

    xpc_connection_t listener = xpc_connection_create_mach_service(A4DJ_SERVICE_NAME, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) {
        logf_("could not publish the service name");
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
            logf_("driver connected");
            handle_peer((xpc_connection_t)peer);
        }
    });
    xpc_connection_resume(listener);
    logf_("a4dj-helper started");
    dispatch_main();
    return 0;
}

#endif /* A4DJ_NO_XPC */
#endif /* A4DJ_NO_MAIN */
