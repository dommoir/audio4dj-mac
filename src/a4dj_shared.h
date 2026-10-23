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
