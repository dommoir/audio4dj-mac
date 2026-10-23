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
