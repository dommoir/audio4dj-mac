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
