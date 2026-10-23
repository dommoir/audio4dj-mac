#!/bin/bash
# a4dj-installer-version: 8
# Builds and installs the Audio 4 DJ driver and its helper service on this Mac, then runs a self-test.
# It asks for your Mac password once. Your audio may cut out for a second while macOS restarts its audio service.
set -e

# what this needs before it can build anything
if [ "$(uname -m)" != "arm64" ]; then
    echo "This driver is for Apple Silicon Macs (M1 or later). This Mac is $(uname -m)."
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
    echo "Apple's Command Line Tools are needed first. Run this, follow the prompts, then run the installer again:"
    echo "    xcode-select --install"
    exit 1
fi
if [ ! -f /opt/homebrew/include/libusb-1.0/libusb.h ] || [ ! -f /opt/homebrew/lib/libusb-1.0.dylib ]; then
    echo "libusb is needed first. Install Homebrew from https://brew.sh, then run this and run the installer again:"
    echo "    brew install libusb"
    exit 1
fi

WORK="$(mktemp -d)"
cd "$WORK"

cat > a4dj_shared.h << 'SHARED_END'
/*
 * a4dj_shared.h - memory shared between the Audio 4 DJ helper service and the Core Audio driver
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The helper owns the USB device. It writes captured audio into in_ring and reads audio to play
 * from out_ring. The driver does the opposite. The driver's sample time IS the helper's frame
 * count, so a frame's position in the ring is simply (frame number modulo ring size).
 */
#ifndef A4DJ_SHARED_H
#define A4DJ_SHARED_H

#include <stdint.h>
#include <string.h>

#define A4DJ_SERVICE_NAME "com.saintdesign.audio4dj.helper"
#define A4DJ_SHM_MAGIC 0xA4D1A4D1u
#define A4DJ_SHM_VERSION 1u
#define A4DJ_CHANNELS 4
#define A4DJ_RING_FRAMES 16384u
#define A4DJ_RATE 44100.0

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t epoch;     /* changes every time the helper restarts the stream: the timeline starts over */
    uint32_t streaming; /* 1 while audio is flowing */
    uint64_t in_frames; /* frames written to in_ring so far */
    uint64_t out_next;  /* next output frame the helper will send to the device */
    uint32_t clk_seq;   /* sequence lock for the clock pair below */
    uint32_t pad0;
    uint64_t clk_frame; /* a frame count ... */
    uint64_t clk_host;  /* ... and the host time (mach ticks) at which that frame happened */
    double clk_tpf;     /* the clock's current rate: host ticks per frame */
    uint32_t pad1[6];
    float in_ring[A4DJ_RING_FRAMES * A4DJ_CHANNELS];
    float out_ring[A4DJ_RING_FRAMES * A4DJ_CHANNELS];
} A4DJShared;

static inline void a4dj_clock_write2(A4DJShared *s, uint64_t frame, uint64_t host, double tpf)
{
    uint32_t a = s->clk_seq;
    __atomic_store_n(&s->clk_seq, a + 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&s->clk_frame, frame, __ATOMIC_RELAXED);
    __atomic_store_n(&s->clk_host, host, __ATOMIC_RELAXED);
    s->clk_tpf = tpf;
    __atomic_store_n(&s->clk_seq, a + 2, __ATOMIC_RELEASE);
}

static inline void a4dj_clock_write(A4DJShared *s, uint64_t frame, uint64_t host)
{
    a4dj_clock_write2(s, frame, host, 0.0);
}

static inline int a4dj_clock_read2(const A4DJShared *s, uint64_t *frame, uint64_t *host, double *tpf)
{
    for (int tries = 0; tries < 8; tries++) {
        uint32_t a = __atomic_load_n(&s->clk_seq, __ATOMIC_ACQUIRE);
        if (a & 1u)
            continue;
        uint64_t f = __atomic_load_n(&s->clk_frame, __ATOMIC_RELAXED);
        uint64_t h = __atomic_load_n(&s->clk_host, __ATOMIC_RELAXED);
        double r = s->clk_tpf;
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&s->clk_seq, __ATOMIC_RELAXED) == a) {
            *frame = f;
            *host = h;
            *tpf = r;
            return 1;
        }
    }
    return 0;
}

static inline int a4dj_clock_read(const A4DJShared *s, uint64_t *frame, uint64_t *host)
{
    double tpf;
    return a4dj_clock_read2(s, frame, host, &tpf);
}

/* Driver side: copy captured frames [t, t+n) out of the ring. Frames not there (yet, or any more) read as silence. */
static inline void a4dj_read_input(const A4DJShared *s, uint64_t t, uint32_t n, float *dst)
{
    uint64_t avail = __atomic_load_n(&s->in_frames, __ATOMIC_ACQUIRE);
    for (uint32_t f = 0; f < n; f++) {
        uint64_t tt = t + f;
        if (tt < avail && avail - tt < A4DJ_RING_FRAMES)
            memcpy(dst + (size_t)f * A4DJ_CHANNELS, &s->in_ring[(tt % A4DJ_RING_FRAMES) * A4DJ_CHANNELS], A4DJ_CHANNELS * sizeof(float));
        else
            memset(dst + (size_t)f * A4DJ_CHANNELS, 0, A4DJ_CHANNELS * sizeof(float));
    }
}

/* Driver side: store frames [t, t+n) for the helper to play. Frames the helper has already passed are dropped. */
static inline void a4dj_write_output(A4DJShared *s, uint64_t t, uint32_t n, const float *src)
{
    uint64_t next = __atomic_load_n(&s->out_next, __ATOMIC_ACQUIRE);
    for (uint32_t f = 0; f < n; f++) {
        uint64_t tt = t + f;
        if (tt < next || tt - next >= A4DJ_RING_FRAMES - 512)
            continue;
        memcpy(&s->out_ring[(tt % A4DJ_RING_FRAMES) * A4DJ_CHANNELS], src + (size_t)f * A4DJ_CHANNELS, A4DJ_CHANNELS * sizeof(float));
    }
}

/*
 * Driver side: the most recent "zero timestamp" (a sample time that is a multiple of period, and the
 * host time it happened at), worked out from the helper's published clock. Returns 0 if the clock is
 * not usable (stale or never set).
 */
static inline int a4dj_zero_timestamp(const A4DJShared *s, uint64_t now_host, double ticks_per_frame, uint32_t period, double *sample_time, uint64_t *host_time)
{
    uint64_t f, h;
    double published_tpf = 0.0;
    if (!a4dj_clock_read2(s, &f, &h, &published_tpf))
        return 0;
    if (published_tpf > 0.0)
        ticks_per_frame = published_tpf; /* the helper's current estimate of the box's rate */
    double ahead = (double)((int64_t)(now_host - h)) / ticks_per_frame;
    double fnow = (double)f + ahead;
    if (fnow < 0.0)
        fnow = 0.0;
    uint64_t z = ((uint64_t)fnow / period) * (uint64_t)period;
    *sample_time = (double)z;
    *host_time = (uint64_t)((int64_t)h + (int64_t)(((double)z - (double)f) * ticks_per_frame));
    return 1;
}

#endif
SHARED_END

cat > a4dj_helper.c << 'HELPER_END'
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
HELPER_END

cat > A4DJDriver.c << 'DRIVER_END'
/*
 * A4DJDriver - Core Audio AudioServerPlugIn that publishes the Audio 4 DJ to macOS
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Publishes a 4 in / 4 out device at 44.1 kHz. The audio comes from and goes to the a4dj-helper
 * service (which owns the USB device) through shared memory that the helper hands over via XPC.
 * If the helper or the box is not there, the device still exists: inputs are silent and the
 * outputs are discarded.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "a4dj_shared.h"

#ifndef A4DJ_NO_XPC
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <xpc/xpc.h>
#endif

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Input = 3,
    kObjectID_Stream_Output = 4
};

#define kDevice_Name "Audio 4 DJ"
#define kDevice_UID "com.saintdesign.audio4dj.device"
#define kDevice_ModelUID "com.saintdesign.audio4dj.model"
#define kManufacturer_Name "Native Instruments"

#define kChannels A4DJ_CHANNELS
#define kSampleRate A4DJ_RATE
#define kZeroTimeStampPeriod 16384

/* How far behind "now" the input is reliably there, and how far ahead the output must be written. Generous
 * to begin with; the helper logs the jitter it actually sees so these can be tightened. */
#define kInputSafetyOffset 1024
#define kOutputSafetyOffset 256
#define kInputLatency 128
#define kOutputLatency 768 /* the helper adds a 512 frame delay on top of the box's own */

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static UInt64 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0.0;
static UInt64 gNumberTimeStamps = 0;
static UInt64 gAnchorHostTime = 0;

static A4DJShared *gShm = NULL; /* shared memory with the helper, once connected */

/* the zero time stamp last handed to Core Audio while following the helper's clock (only the I/O thread touches these) */
static Float64 gZtsSample = -1.0;
static UInt64 gZtsHost = 0;
static UInt64 gZtsSeed = 0;
static int64_t gShmPid = 0;     /* which helper process that memory belongs to */

#ifndef A4DJ_NO_XPC
static xpc_connection_t gConn = NULL;
static dispatch_queue_t gQueue = NULL;
static dispatch_source_t gTimer = NULL;
#define A4LOG(msg) os_log(OS_LOG_DEFAULT, "Audio4DJ driver: %{public}s", msg)
#endif

/* ------------------------------------------------------------------ helper connection */

#ifndef A4DJ_NO_XPC

/* Runs once a second on gQueue: connect to the helper if not connected, and notice if it restarted. */
static void A4DJ_TryConnect(void)
{
    if (gConn == NULL) {
        gConn = xpc_connection_create_mach_service(A4DJ_SERVICE_NAME, gQueue, 0);
        if (gConn == NULL)
            return;
        xpc_connection_set_event_handler(gConn, ^(xpc_object_t event) {
            if (event == XPC_ERROR_CONNECTION_INVALID) {
                xpc_connection_t dead = gConn;
                gConn = NULL;
                if (dead != NULL)
                    xpc_release(dead);
            }
        });
        xpc_connection_resume(gConn);
    }
    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "cmd", "map");
    xpc_connection_send_message_with_reply(gConn, msg, gQueue, ^(xpc_object_t reply) {
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
            return;
        int64_t pid = xpc_dictionary_get_int64(reply, "pid");
        if (gShm != NULL && pid == gShmPid)
            return;
        xpc_object_t shm = xpc_dictionary_get_value(reply, "shm");
        if (shm == NULL)
            return;
        void *region = NULL;
        size_t len = xpc_shmem_map(shm, &region);
        if (region != NULL && len >= sizeof(A4DJShared) && ((A4DJShared *)region)->magic == A4DJ_SHM_MAGIC) {
            gShmPid = pid;
            __atomic_store_n(&gShm, (A4DJShared *)region, __ATOMIC_RELEASE);
            A4LOG("connected to the helper");
        }
    });
    xpc_release(msg);
}

static void A4DJ_StartHelperLink(void)
{
    gQueue = dispatch_queue_create("com.saintdesign.audio4dj.driver", NULL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 1ull * NSEC_PER_SEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{
        A4DJ_TryConnect();
    });
    dispatch_resume(gTimer);
}

#endif

#ifdef A4DJ_TEST
void A4DJ_TestSetShm(A4DJShared *s)
{
    gShm = s;
}
#endif

/* ------------------------------------------------------------------ interface table */

static HRESULT A4DJ_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG A4DJ_AddRef(void *inDriver);
static ULONG A4DJ_Release(void *inDriver);
static OSStatus A4DJ_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus A4DJ_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus A4DJ_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus A4DJ_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus A4DJ_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus A4DJ_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus A4DJ_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean A4DJ_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus A4DJ_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus A4DJ_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus A4DJ_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus A4DJ_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus A4DJ_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus A4DJ_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus A4DJ_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus A4DJ_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus A4DJ_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus A4DJ_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus A4DJ_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    A4DJ_QueryInterface,
    A4DJ_AddRef,
    A4DJ_Release,
    A4DJ_Initialize,
    A4DJ_CreateDevice,
    A4DJ_DestroyDevice,
    A4DJ_AddDeviceClient,
    A4DJ_RemoveDeviceClient,
    A4DJ_PerformDeviceConfigurationChange,
    A4DJ_AbortDeviceConfigurationChange,
    A4DJ_HasProperty,
    A4DJ_IsPropertySettable,
    A4DJ_GetPropertyDataSize,
    A4DJ_GetPropertyData,
    A4DJ_SetPropertyData,
    A4DJ_StartIO,
    A4DJ_StopIO,
    A4DJ_GetZeroTimeStamp,
    A4DJ_WillDoIOOperation,
    A4DJ_BeginIOOperation,
    A4DJ_DoIOOperation,
    A4DJ_EndIOOperation};
static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

/* The factory named in Info.plist. The HAL calls this to get the driver. */
void *A4DJ_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
        return gDriverRef;
    return NULL;
}

/* ------------------------------------------------------------------ COM boilerplate */

static HRESULT A4DJ_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (outInterface == NULL)
        return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL)
        return kAudioHardwareIllegalOperationError;
    HRESULT answer = 0;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
    } else {
        answer = E_NOINTERFACE;
    }
    CFRelease(requested);
    return answer;
}

static ULONG A4DJ_AddRef(void *inDriver)
{
    ULONG answer = 0;
    if (inDriver != gDriverRef)
        return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX)
        ++gRefCount;
    answer = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return answer;
}

static ULONG A4DJ_Release(void *inDriver)
{
    ULONG answer = 0;
    if (inDriver != gDriverRef)
        return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0)
        --gRefCount;
    answer = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return answer;
}

/* ------------------------------------------------------------------ basic operations */

static OSStatus A4DJ_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    gHost = inHost;

    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostClockFrequency = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
#ifndef A4DJ_NO_XPC
    A4DJ_StartHelperLink();
#endif
    return 0;
}

static OSStatus A4DJ_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus A4DJ_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDeviceObjectID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus A4DJ_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus A4DJ_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus A4DJ_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inChangeAction;
    (void)inChangeInfo;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus A4DJ_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inChangeAction;
    (void)inChangeInfo;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    return 0;
}

/* ------------------------------------------------------------------ properties
 *
 * Each object has one function that builds a property's value into a scratch buffer and says
 * how big it is. HasProperty, IsPropertySettable, GetPropertyDataSize and GetPropertyData are all
 * answered from it, so they cannot disagree with each other.
 *
 * 'elem' is the size of one list element for list properties (the caller may ask for fewer
 * elements than exist), or 0 for single values.
 */

#define PUT(type, value)                \
    do {                                \
        *(type *)out = (value);         \
        *size = (UInt32)sizeof(type);   \
    } while (0)

static void fill_format(AudioStreamBasicDescription *f)
{
    memset(f, 0, sizeof *f);
    f->mSampleRate = kSampleRate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket = kChannels * sizeof(Float32);
    f->mFramesPerPacket = 1;
    f->mBytesPerFrame = kChannels * sizeof(Float32);
    f->mChannelsPerFrame = kChannels;
    f->mBitsPerChannel = 32;
}

static OSStatus PlugIn_Get(const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, uint8_t *out, UInt32 *size, Boolean *settable, UInt32 *elem)
{
    *settable = false;
    *elem = 0;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        PUT(AudioClassID, kAudioObjectClassID);
        break;
    case kAudioObjectPropertyClass:
        PUT(AudioClassID, kAudioPlugInClassID);
        break;
    case kAudioObjectPropertyOwner:
        PUT(AudioObjectID, kAudioObjectUnknown);
        break;
    case kAudioObjectPropertyManufacturer:
        PUT(CFStringRef, CFSTR(kManufacturer_Name));
        break;
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        ((AudioObjectID *)out)[0] = kObjectID_Device;
        *size = sizeof(AudioObjectID);
        *elem = sizeof(AudioObjectID);
        break;
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        CFStringRef uid = (qs == sizeof(CFStringRef) && q != NULL) ? *(CFStringRef *)q : NULL;
        AudioObjectID result = kAudioObjectUnknown;
        if (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
            result = kObjectID_Device;
        PUT(AudioObjectID, result);
        break;
    }
    case kAudioPlugInPropertyResourceBundle:
        PUT(CFStringRef, CFSTR(""));
        break;
    default:
        return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Device_Get(const AudioObjectPropertyAddress *a, uint8_t *out, UInt32 *size, Boolean *settable, UInt32 *elem)
{
    *settable = false;
    *elem = 0;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        PUT(AudioClassID, kAudioObjectClassID);
        break;
    case kAudioObjectPropertyClass:
        PUT(AudioClassID, kAudioDeviceClassID);
        break;
    case kAudioObjectPropertyOwner:
        PUT(AudioObjectID, kObjectID_PlugIn);
        break;
    case kAudioObjectPropertyName:
        PUT(CFStringRef, CFSTR(kDevice_Name));
        break;
    case kAudioObjectPropertyManufacturer:
        PUT(CFStringRef, CFSTR(kManufacturer_Name));
        break;
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams: {
        AudioObjectID *o = (AudioObjectID *)out;
        UInt32 n = 0;
        if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput)
            o[n++] = kObjectID_Stream_Input;
        if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput)
            o[n++] = kObjectID_Stream_Output;
        *size = n * (UInt32)sizeof(AudioObjectID);
        *elem = sizeof(AudioObjectID);
        break;
    }
    case kAudioObjectPropertyControlList:
        *size = 0;
        *elem = sizeof(AudioObjectID);
        break;
    case kAudioDevicePropertyDeviceUID:
        PUT(CFStringRef, CFSTR(kDevice_UID));
        break;
    case kAudioDevicePropertyModelUID:
        PUT(CFStringRef, CFSTR(kDevice_ModelUID));
        break;
    case kAudioDevicePropertyTransportType:
        PUT(UInt32, kAudioDeviceTransportTypeUSB);
        break;
    case kAudioDevicePropertyRelatedDevices:
        ((AudioObjectID *)out)[0] = kObjectID_Device;
        *size = sizeof(AudioObjectID);
        *elem = sizeof(AudioObjectID);
        break;
    case kAudioDevicePropertyClockDomain:
        PUT(UInt32, 0);
        break;
    case kAudioDevicePropertyDeviceIsAlive:
        PUT(UInt32, 1);
        break;
    case kAudioDevicePropertyDeviceIsRunning:
        pthread_mutex_lock(&gStateMutex);
        PUT(UInt32, gIOCount > 0 ? 1 : 0);
        pthread_mutex_unlock(&gStateMutex);
        break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        PUT(UInt32, 1);
        break;
    case kAudioDevicePropertyLatency:
        PUT(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? kInputLatency : kOutputLatency);
        break;
    case kAudioDevicePropertySafetyOffset:
        PUT(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? kInputSafetyOffset : kOutputSafetyOffset);
        break;
    case kAudioDevicePropertyNominalSampleRate:
        *settable = true;
        PUT(Float64, kSampleRate);
        break;
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange r;
        r.mMinimum = kSampleRate;
        r.mMaximum = kSampleRate;
        memcpy(out, &r, sizeof r);
        *size = sizeof r;
        *elem = sizeof r;
        break;
    }
    case kAudioDevicePropertyIsHidden:
        PUT(UInt32, 0);
        break;
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 ch[2] = {1, 2};
        memcpy(out, ch, sizeof ch);
        *size = sizeof ch;
        break;
    }
    case kAudioDevicePropertyZeroTimeStampPeriod:
        PUT(UInt32, kZeroTimeStampPeriod);
        break;
    default:
        return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Stream_Get(AudioObjectID obj, const AudioObjectPropertyAddress *a, uint8_t *out, UInt32 *size, Boolean *settable, UInt32 *elem)
{
    *settable = false;
    *elem = 0;
    int is_input = (obj == kObjectID_Stream_Input);
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        PUT(AudioClassID, kAudioObjectClassID);
        break;
    case kAudioObjectPropertyClass:
        PUT(AudioClassID, kAudioStreamClassID);
        break;
    case kAudioObjectPropertyOwner:
        PUT(AudioObjectID, kObjectID_Device);
        break;
    case kAudioObjectPropertyOwnedObjects:
        *size = 0;
        *elem = sizeof(AudioObjectID);
        break;
    case kAudioStreamPropertyIsActive:
        *settable = true;
        PUT(UInt32, 1);
        break;
    case kAudioStreamPropertyDirection:
        PUT(UInt32, is_input ? 1 : 0);
        break;
    case kAudioStreamPropertyTerminalType:
        PUT(UInt32, kAudioStreamTerminalTypeLine);
        break;
    case kAudioStreamPropertyStartingChannel:
        PUT(UInt32, 1);
        break;
    case kAudioStreamPropertyLatency:
        PUT(UInt32, 0);
        break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription f;
        fill_format(&f);
        memcpy(out, &f, sizeof f);
        *size = sizeof f;
        *settable = true;
        break;
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription f;
        memset(&f, 0, sizeof f);
        fill_format(&f.mFormat);
        f.mSampleRateRange.mMinimum = kSampleRate;
        f.mSampleRateRange.mMaximum = kSampleRate;
        memcpy(out, &f, sizeof f);
        *size = sizeof f;
        *elem = sizeof f;
        break;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Object_Get(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, uint8_t *out, UInt32 *size, Boolean *settable, UInt32 *elem)
{
    switch (obj) {
    case kObjectID_PlugIn:
        return PlugIn_Get(a, qs, q, out, size, settable, elem);
    case kObjectID_Device:
        return Device_Get(a, out, size, settable, elem);
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        return Stream_Get(obj, a, out, size, settable, elem);
    default:
        return kAudioHardwareBadObjectError;
    }
}

static Boolean A4DJ_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL)
        return false;
    uint8_t scratch[256];
    UInt32 size = 0, elem = 0;
    Boolean settable = false;
    return Object_Get(inObjectID, inAddress, 0, NULL, scratch, &size, &settable, &elem) == 0;
}

static OSStatus A4DJ_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL)
        return kAudioHardwareIllegalOperationError;
    uint8_t scratch[256];
    UInt32 size = 0, elem = 0;
    return Object_Get(inObjectID, inAddress, 0, NULL, scratch, &size, outIsSettable, &elem);
}

static OSStatus A4DJ_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL)
        return kAudioHardwareIllegalOperationError;
    uint8_t scratch[256];
    UInt32 elem = 0;
    Boolean settable = false;
    return Object_Get(inObjectID, inAddress, inQualifierDataSize, inQualifierData, scratch, outDataSize, &settable, &elem);
}

static OSStatus A4DJ_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL)
        return kAudioHardwareIllegalOperationError;
    uint8_t scratch[256];
    UInt32 size = 0, elem = 0;
    Boolean settable = false;
    OSStatus status = Object_Get(inObjectID, inAddress, inQualifierDataSize, inQualifierData, scratch, &size, &settable, &elem);
    if (status != 0)
        return status;
    if (elem == 0) {
        if (inDataSize < size)
            return kAudioHardwareBadPropertySizeError;
    } else {
        UInt32 fit = (inDataSize / elem) * elem;
        if (fit < size)
            size = fit;
    }
    memcpy(outData, scratch, size);
    *outDataSize = size;
    return 0;
}

static OSStatus A4DJ_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData)
{
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inAddress == NULL)
        return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64))
            return kAudioHardwareBadPropertySizeError;
        Float64 rate = *(const Float64 *)inData;
        return (rate == kSampleRate) ? 0 : kAudioHardwareIllegalOperationError;
    }
    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        if (inAddress->mSelector == kAudioStreamPropertyIsActive)
            return 0;
        if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inDataSize != sizeof(AudioStreamBasicDescription))
                return kAudioHardwareBadPropertySizeError;
            AudioStreamBasicDescription want;
            fill_format(&want);
            const AudioStreamBasicDescription *got = (const AudioStreamBasicDescription *)inData;
            int same = got->mSampleRate == want.mSampleRate && got->mFormatID == want.mFormatID && got->mChannelsPerFrame == want.mChannelsPerFrame &&
                       got->mBitsPerChannel == want.mBitsPerChannel;
            return same ? 0 : kAudioDeviceUnsupportedFormatError;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

/* ------------------------------------------------------------------ I/O */

static OSStatus A4DJ_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == UINT64_MAX) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    ++gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus A4DJ_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0)
        --gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus A4DJ_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;

    /* Preferred: follow the box's own clock, as published by the helper. */
    A4DJShared *s = __atomic_load_n(&gShm, __ATOMIC_ACQUIRE);
    if (s != NULL && __atomic_load_n(&s->streaming, __ATOMIC_ACQUIRE)) {
        UInt64 now = mach_absolute_time();
        uint64_t f, h;
        int64_t fresh_limit = (int64_t)(0.25 * kSampleRate * gHostTicksPerFrame); /* a quarter of a second */
        if (a4dj_clock_read(s, &f, &h) && (int64_t)(now - h) < fresh_limit) {
            Float64 sampleTime;
            UInt64 hostTime;
            if (a4dj_zero_timestamp(s, now, gHostTicksPerFrame, kZeroTimeStampPeriod, &sampleTime, &hostTime)) {
                /* Core Audio must see the same time stamp for a whole period: work it out once, when the
                 * period begins, and repeat it until the next one. Recomputing it on every call makes it
                 * wobble slightly, and Core Audio then keeps re-syncing and drops audio. */
                UInt64 seed = 2 + (UInt64)__atomic_load_n(&s->epoch, __ATOMIC_ACQUIRE);
                if (seed != gZtsSeed || sampleTime > gZtsSample) {
                    gZtsSeed = seed;
                    gZtsSample = sampleTime;
                    gZtsHost = hostTime;
                }
                *outSampleTime = gZtsSample;
                *outHostTime = gZtsHost;
                *outSeed = gZtsSeed;
                return 0;
            }
        }
    }

    /* Otherwise run on the Mac's own clock so the device still behaves. */
    pthread_mutex_lock(&gStateMutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    Float64 hostTickOffset = (Float64)(gNumberTimeStamps + 1) * hostTicksPerPeriod;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)hostTickOffset;
    if (nextHostTime <= currentHostTime)
        ++gNumberTimeStamps;
    *outSampleTime = (Float64)(gNumberTimeStamps * (UInt64)kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * hostTicksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus A4DJ_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    Boolean willDo = false;
    switch (inOperationID) {
    case kAudioServerPlugInIOOperationReadInput:
    case kAudioServerPlugInIOOperationWriteMix:
        willDo = true;
        break;
    default:
        break;
    }
    if (outWillDo)
        *outWillDo = willDo;
    if (outWillDoInPlace)
        *outWillDoInPlace = true;
    return 0;
}

static OSStatus A4DJ_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus A4DJ_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inClientID;
    (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    if (inStreamObjectID != kObjectID_Stream_Input && inStreamObjectID != kObjectID_Stream_Output)
        return kAudioHardwareBadObjectError;

    A4DJShared *s = __atomic_load_n(&gShm, __ATOMIC_ACQUIRE);
    int live = (s != NULL) && __atomic_load_n(&s->streaming, __ATOMIC_ACQUIRE);

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        Float32 *dst = (Float32 *)ioMainBuffer;
        if (live && inIOCycleInfo->mInputTime.mSampleTime >= 0.0)
            a4dj_read_input(s, (uint64_t)inIOCycleInfo->mInputTime.mSampleTime, inIOBufferFrameSize, dst);
        else
            memset(dst, 0, (size_t)inIOBufferFrameSize * kChannels * sizeof(Float32));
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        if (live && inIOCycleInfo->mOutputTime.mSampleTime >= 0.0)
            a4dj_write_output(s, (uint64_t)inIOCycleInfo->mOutputTime.mSampleTime, inIOBufferFrameSize, (const Float32 *)ioMainBuffer);
    }
    return 0;
}

static OSStatus A4DJ_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    if (inDriver != gDriverRef)
        return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)
        return kAudioHardwareBadObjectError;
    return 0;
}
DRIVER_END

cat > a4dj_selftest.c << 'SELFTEST_END'
/*
 * a4dj_selftest - plays a quiet tone out of the "Audio 4 DJ" Core Audio device on all four outputs
 * while recording its four inputs, then reports the levels it heard and, on the channel that carries the
 * tone back (a cable looping an output to an input), counts dropouts and sudden jumps in it.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Build: clang -O2 -o a4dj-selftest a4dj_selftest.c -framework CoreAudio -framework CoreFoundation -lm
 * Run:   ./a4dj-selftest [seconds]   (default 4, at most 60; tone at -45 dBFS)
 */

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEVICE_UID "com.saintdesign.audio4dj.device"
#define TONE_HZ 1000.0
#define TONE_LEVEL 0.0056 /* -45 dBFS: the phono inputs add about 30 dB, so this stays clear of clipping */

typedef struct {
    double phase;
    uint64_t calls, in_frames, out_frames;
    double peak[4], sumsq[4];
    uint64_t nonzero_in;
    int in_channels, out_channels;
    float *rec[4];
    uint64_t rec_cap;
    uint64_t t_start, t_last;
    double first_ms, max_gap_ms;
    uint64_t long_gaps;
    struct mach_timebase_info tb;
    /* one entry per I/O callback, saved for inspection */
    uint64_t cb_cap;
    double *cb_ms, *cb_in_st, *cb_out_st;
    uint32_t *cb_frames;
} Ctx;

static OSStatus io_proc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *in_time, AudioBufferList *out,
                        const AudioTimeStamp *out_time, void *client)
{
    (void)dev;
    (void)now;
    Ctx *c = (Ctx *)client;
    c->calls++;
    {
        uint64_t t = mach_absolute_time();
        double to_ms = 1e-6 * (double)c->tb.numer / (double)c->tb.denom;
        if (c->calls == 1) {
            c->first_ms = (double)(t - c->t_start) * to_ms;
        } else {
            double gap = (double)(t - c->t_last) * to_ms;
            UInt32 n = (in != NULL && in->mNumberBuffers > 0 && in->mBuffers[0].mNumberChannels) ? in->mBuffers[0].mDataByteSize / (in->mBuffers[0].mNumberChannels * (UInt32)sizeof(float)) : 512;
            double nominal = 1000.0 * (double)n / 44100.0;
            if (gap > c->max_gap_ms)
                c->max_gap_ms = gap;
            if (gap > 2.0 * nominal)
                c->long_gaps++;
        }
        c->t_last = t;
        uint64_t idx = c->calls - 1;
        if (idx < c->cb_cap) {
            UInt32 n = 0;
            if (in != NULL && in->mNumberBuffers > 0 && in->mBuffers[0].mNumberChannels)
                n = in->mBuffers[0].mDataByteSize / (in->mBuffers[0].mNumberChannels * (UInt32)sizeof(float));
            c->cb_ms[idx] = (double)(t - c->t_start) * to_ms;
            c->cb_in_st[idx] = in_time ? in_time->mSampleTime : -1.0;
            c->cb_out_st[idx] = out_time ? out_time->mSampleTime : -1.0;
            c->cb_frames[idx] = n;
        }
    }

    if (in != NULL && in->mNumberBuffers > 0) {
        const float *x = (const float *)in->mBuffers[0].mData;
        UInt32 ch = in->mBuffers[0].mNumberChannels;
        UInt32 frames = ch ? in->mBuffers[0].mDataByteSize / (ch * (UInt32)sizeof(float)) : 0;
        c->in_channels = (int)ch;
        for (UInt32 f = 0; f < frames; f++) {
            for (UInt32 k = 0; k < ch && k < 4; k++) {
                double v = (double)x[f * ch + k];
                if (fabs(v) > c->peak[k])
                    c->peak[k] = fabs(v);
                c->sumsq[k] += v * v;
                if (v != 0.0)
                    c->nonzero_in++;
                if (c->in_frames + f < c->rec_cap)
                    c->rec[k][c->in_frames + f] = (float)v;
            }
        }
        c->in_frames += frames;
    }

    if (out != NULL && out->mNumberBuffers > 0) {
        float *y = (float *)out->mBuffers[0].mData;
        UInt32 ch = out->mBuffers[0].mNumberChannels;
        UInt32 frames = ch ? out->mBuffers[0].mDataByteSize / (ch * (UInt32)sizeof(float)) : 0;
        c->out_channels = (int)ch;
        for (UInt32 f = 0; f < frames; f++) {
            float s = (float)(TONE_LEVEL * sin(c->phase));
            c->phase += 2.0 * M_PI * TONE_HZ / 44100.0;
            if (c->phase > 2.0 * M_PI)
                c->phase -= 2.0 * M_PI;
            for (UInt32 k = 0; k < ch; k++)
                y[f * ch + k] = s;
        }
        c->out_frames += frames;
    }
    return 0;
}

/* Counts, in a recorded 1 kHz tone, stretches of exact silence and sudden jumps in the waveform. */
static void count_glitches(const float *x, uint64_t n, uint64_t skip, uint64_t *zero_runs, uint64_t *jumps)
{
    double pk = 0.0;
    for (uint64_t i = skip; i < n; i++)
        if (fabs((double)x[i]) > pk)
            pk = fabs((double)x[i]);
    double thr = 0.3 * pk; /* a clean 1 kHz sine never moves more than about 0.14 of its peak between samples */
    uint64_t run = 0;
    *zero_runs = 0;
    *jumps = 0;
    for (uint64_t i = skip + 1; i < n; i++) {
        if (fabs((double)x[i]) < 1e-9) {
            if (++run == 16)
                (*zero_runs)++;
        } else {
            run = 0;
        }
        if (fabs((double)x[i] - (double)x[i - 1]) > thr)
            (*jumps)++;
    }
}

/* Saves what happened, for inspection: every callback's timing and sample times, then the loudest input channel. */
static void save_recording(const Ctx *ctx, int best, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return;
    uint32_t magic = 0xA4D15E1Fu, ncb = (uint32_t)(ctx->calls < ctx->cb_cap ? ctx->calls : ctx->cb_cap);
    fwrite(&magic, 4, 1, f);
    fwrite(&ncb, 4, 1, f);
    for (uint32_t i = 0; i < ncb; i++) {
        fwrite(&ctx->cb_ms[i], 8, 1, f);
        fwrite(&ctx->cb_in_st[i], 8, 1, f);
        fwrite(&ctx->cb_out_st[i], 8, 1, f);
        fwrite(&ctx->cb_frames[i], 4, 1, f);
    }
    uint32_t ns = (uint32_t)(ctx->in_frames < ctx->rec_cap ? ctx->in_frames : ctx->rec_cap);
    fwrite(&ns, 4, 1, f);
    fwrite(ctx->rec[best], sizeof(float), ns, f);
    fclose(f);
}

static double dbfs(double v)
{
    return v <= 0.0 ? -200.0 : 20.0 * log10(v);
}

int main(int argc, char **argv)
{
    int seconds = 4;
    if (argc > 1)
        seconds = atoi(argv[1]);
    if (seconds < 1)
        seconds = 1;
    if (seconds > 60)
        seconds = 60;
    CFStringRef uid = CFSTR(DEVICE_UID);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    AudioObjectPropertyAddress addr = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof uid, &uid, &size, &dev);
    if (st != 0 || dev == kAudioObjectUnknown) {
        printf("The Audio 4 DJ device is not there. Is the driver installed?\n");
        return 2;
    }
    printf("found the Audio 4 DJ device (id %u)\n", (unsigned)dev);

    Ctx ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.rec_cap = (uint64_t)(seconds + 2) * 44100;
    for (int k = 0; k < 4; k++)
        ctx.rec[k] = (float *)calloc((size_t)ctx.rec_cap, sizeof(float));
    mach_timebase_info(&ctx.tb);
    ctx.cb_cap = 4096;
    ctx.cb_ms = (double *)calloc(ctx.cb_cap, sizeof(double));
    ctx.cb_in_st = (double *)calloc(ctx.cb_cap, sizeof(double));
    ctx.cb_out_st = (double *)calloc(ctx.cb_cap, sizeof(double));
    ctx.cb_frames = (uint32_t *)calloc(ctx.cb_cap, sizeof(uint32_t));
    AudioDeviceIOProcID proc = NULL;
    st = AudioDeviceCreateIOProcID(dev, io_proc, &ctx, &proc);
    if (st != 0) {
        printf("could not create the I/O callback (%d)\n", (int)st);
        return 3;
    }
    ctx.t_start = mach_absolute_time();
    st = AudioDeviceStart(dev, proc);
    if (st != 0) {
        printf("could not start the device (%d)\n", (int)st);
        return 3;
    }
    printf("playing a 1 kHz tone at -45 dBFS on all four outputs and recording for %d seconds ...\n", seconds);
    sleep((unsigned)seconds);
    Float64 actual_rate = 0.0;
    {
        UInt32 rsz = sizeof actual_rate;
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyActualSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(dev, &ra, 0, NULL, &rsz, &actual_rate) != 0)
            actual_rate = -1.0;
    }
    AudioDeviceStop(dev, proc);
    AudioDeviceDestroyIOProcID(dev, proc);

    printf("\nI/O callbacks %llu, input frames %llu, output frames %llu (expect about %d each)\n", (unsigned long long)ctx.calls,
           (unsigned long long)ctx.in_frames, (unsigned long long)ctx.out_frames, seconds * 44100);
    printf("timing: first callback %.0f ms after start, longest gap between callbacks %.1f ms, gaps over twice the buffer time: %llu\n", ctx.first_ms,
           ctx.max_gap_ms, (unsigned long long)ctx.long_gaps);
    {
        uint64_t m = ctx.calls < ctx.cb_cap ? ctx.calls : ctx.cb_cap;
        double mean = m > 1 ? (ctx.cb_ms[m - 1] - ctx.cb_ms[0]) / (double)(m - 1) : 0.0;
        printf("Core Audio measured the device clock at %.0f Hz (it should be 44100). Last callback came %.1f s after start; the average gap between callbacks was %.1f ms (a 512 frame buffer at 44.1 kHz is 11.6 ms).\n",
               (double)actual_rate, m ? ctx.cb_ms[m - 1] / 1000.0 : 0.0, mean);
    }
    if (ctx.in_frames == 0) {
        printf("FAIL: no audio was delivered\n");
        return 1;
    }
    static const char *names[4] = {"in1 L", "in1 R", "in2 L", "in2 R"};
    int heard = 0;
    for (int k = 0; k < 4; k++) {
        double rms = sqrt(ctx.sumsq[k] / (double)ctx.in_frames);
        printf("  %s   peak %7.1f dBFS   rms %7.1f dBFS\n", names[k], dbfs(ctx.peak[k]), dbfs(rms));
        if (dbfs(rms) > -50.0)
            heard = 1;
    }
    if (ctx.nonzero_in == 0) {
        printf("\nEvery input sample was exactly zero: the driver is running but not receiving audio from the box.\n");
        return 1;
    }
    if (!heard) {
        printf("\nThe inputs are live but quiet. With no cable looping an output to an input, that is expected.\n");
        return 0;
    }

    /* the loudest input is the one the cable loops back to: look for glitches in it */
    int best = 0;
    for (int k = 1; k < 4; k++)
        if (ctx.sumsq[k] > ctx.sumsq[best])
            best = k;
    const float *x = ctx.rec[best];
    save_recording(&ctx, best, "/tmp/a4dj_selftest.dat");
    uint64_t n = ctx.in_frames < ctx.rec_cap ? ctx.in_frames : ctx.rec_cap;
    uint64_t skip = 22050; /* ignore the first half second while everything settles */
    uint64_t zero_runs = 0, jumps = 0;
    count_glitches(x, n, skip, &zero_runs, &jumps);
    printf("\nThe tone comes back on %s. Over %.1f seconds of it:\n", names[best], (double)(n - skip) / 44100.0);
    printf("  dropouts (stretches of exact silence)   %llu\n", (unsigned long long)zero_runs);
    printf("  sudden jumps in the waveform            %llu\n", (unsigned long long)jumps);
    if (zero_runs == 0 && jumps == 0)
        printf("\nPASS: clean, no glitches found.\n");
    else
        printf("\nGLITCHES FOUND: audio is being interrupted somewhere between the Mac and the box.\n");
    return 0;
}
SELFTEST_END

cat > Info.plist << 'PLIST_END'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>Audio4DJ</string>
	<key>CFBundleIdentifier</key>
	<string>com.saintdesign.audio4dj.driver</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Audio4DJ</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.3</string>
	<key>CFBundleVersion</key>
	<string>3</string>
	<key>AudioServerPlugIn_MachServices</key>
	<array>
		<string>com.saintdesign.audio4dj.helper</string>
	</array>
	<key>CFPlugInFactories</key>
	<dict>
		<key>7C3B6C02-6A7E-4E6B-9B1C-5D4E3A2F1A01</key>
		<string>A4DJ_Create</string>
	</dict>
	<key>CFPlugInTypes</key>
	<dict>
		<key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
		<array>
			<string>7C3B6C02-6A7E-4E6B-9B1C-5D4E3A2F1A01</string>
		</array>
	</dict>
</dict>
</plist>
PLIST_END

cat > helper.plist << 'DAEMON_END'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.saintdesign.audio4dj.helper</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/libexec/a4dj-helper</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>com.saintdesign.audio4dj.helper</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/var/log/a4dj-helper.log</string>
	<key>StandardOutPath</key>
	<string>/var/log/a4dj-helper.log</string>
</dict>
</plist>
DAEMON_END

echo "Building..."
clang -O2 -Wall -o a4dj-helper a4dj_helper.c -I/opt/homebrew/include/libusb-1.0 -L/opt/homebrew/lib -lusb-1.0 -lm
clang -O2 -Wall -o a4dj-selftest a4dj_selftest.c -framework CoreAudio -framework CoreFoundation -lm
mkdir -p Audio4DJ.driver/Contents/MacOS
cp Info.plist Audio4DJ.driver/Contents/Info.plist
clang -O2 -Wall -bundle -arch arm64 -o Audio4DJ.driver/Contents/MacOS/Audio4DJ A4DJDriver.c -framework CoreAudio -framework CoreFoundation
codesign --force --sign - a4dj-helper
codesign --force --sign - a4dj-selftest
codesign --force --sign - Audio4DJ.driver

echo "Installing (your Mac password may be asked for)..."
sudo mkdir -p /usr/local/libexec /usr/local/bin
sudo cp a4dj-helper /usr/local/libexec/a4dj-helper
sudo chown root:wheel /usr/local/libexec/a4dj-helper
sudo chmod 755 /usr/local/libexec/a4dj-helper
sudo cp a4dj-selftest /usr/local/bin/a4dj-selftest
sudo chmod 755 /usr/local/bin/a4dj-selftest
sudo cp helper.plist /Library/LaunchDaemons/com.saintdesign.audio4dj.helper.plist
sudo chown root:wheel /Library/LaunchDaemons/com.saintdesign.audio4dj.helper.plist
sudo chmod 644 /Library/LaunchDaemons/com.saintdesign.audio4dj.helper.plist
sudo launchctl bootout system/com.saintdesign.audio4dj.helper 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.saintdesign.audio4dj.helper.plist

sudo rm -rf /Library/Audio/Plug-Ins/HAL/Audio4DJ.driver
sudo cp -R Audio4DJ.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/Audio4DJ.driver
sudo killall coreaudiod || true

echo ""
echo "Installed. Waiting a few seconds for everything to start, then running the self-test (10 seconds)..."
sleep 8
echo ""
echo "--- helper log (last lines) ---"
tail -n 8 /var/log/a4dj-helper.log 2>/dev/null || echo "(no helper log yet)"
echo ""
echo "--- self-test ---"
/usr/local/bin/a4dj-selftest 10 || true
echo ""
echo "If you report a problem, attach /tmp/a4dj_selftest.dat and /var/log/a4dj-helper.log."
