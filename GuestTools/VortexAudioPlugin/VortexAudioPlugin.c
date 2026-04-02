/*
 * VortexAudioPlugin.c -- CoreAudio HAL AudioServerPlugin for Vortex VMs.
 *
 * This plugin registers a virtual "Vortex Audio" device with CoreAudio inside
 * a macOS guest VM. It provides one stereo output stream and one stereo input
 * stream, both at 48 kHz Float32. Audio data passes through lock-free ring
 * buffers that will later be connected to the host via virtio-vsock transport.
 *
 * The plugin implements the AudioServerPlugInDriverInterface vtable required
 * by the HAL. It is loaded from /Library/Audio/Plug-Ins/HAL/ as a .driver
 * bundle by the audio server process (coreaudiod).
 *
 * Object hierarchy:
 *   kAudioObjectPlugInObject (ID 1) -- the plugin singleton
 *     -> kVortexDeviceID (ID 2) -- "Vortex Audio" device
 *          -> kVortexOutputStreamID (ID 3) -- stereo output stream
 *          -> kVortexInputStreamID  (ID 4) -- stereo input stream
 *
 * RT-safety: DoIOOperation, GetZeroTimeStamp, BeginIOOperation, and
 * EndIOOperation run on the audio server's real-time thread. They must not
 * allocate, lock, or make syscalls. All shared state accessed from these paths
 * uses lock-free atomics.
 *
 * Copyright 2024-2026 Vortex Authors. All rights reserved.
 * SPDX-License-Identifier: MIT
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <stdatomic.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

#include "VortexSharedAudio.h"

/* ========================================================================== */
#pragma mark - Constants
/* ========================================================================== */

/* Object IDs -- fixed, since we only ever have one device and two streams. */
enum {
    kVortexDeviceID         = 2,
    kVortexOutputStreamID   = 3,
    kVortexInputStreamID    = 4,
    kVortexObjectCount      = 4  /* plugin(1) + device + 2 streams */
};

/* Audio format defaults. */
#define kVortexNumChannels          2
#define kVortexBitsPerChannel       32
#define kVortexBytesPerFrame        (kVortexNumChannels * (kVortexBitsPerChannel / 8))
#define kVortexDefaultSampleRate    48000.0

/* Supported sample rates. */
static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 96000.0 };
#define kNumSupportedSampleRates (sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]))

/*
 * Ring buffer capacity in samples. Now derived from VortexSharedAudio.h so
 * the HAL plugin and daemon agree on the shared memory ring geometry.
 */
#define kRingBufferSampleCapacity   VORTEX_RING_SAMPLES
#define kRingBufferFrameCapacity    VORTEX_RING_FRAMES

/*
 * The zero-timestamp period in frames. The HAL calls GetZeroTimeStamp on
 * every IO cycle; we report a new timestamp every this-many frames. Must
 * be >= 10923 per the AudioServerPlugIn.h docs.
 */
#define kZeroTimestampPeriod        (kRingBufferFrameCapacity)

/* Device buffer size range (frames). */
#define kMinIOBufferFrames  64
#define kMaxIOBufferFrames  4096
#define kDefaultIOBufferFrames 512

/* String constants. */
#define kVortexDeviceName           "Vortex Audio"
#define kVortexDeviceUID            "VortexAudioDevice"
#define kVortexModelUID             "VortexAudioModel"
#define kVortexManufacturer         "Vortex"
#define kVortexBundleID             "com.vortex.audio.plugin"

/* ========================================================================== */
#pragma mark - Logging
/* ========================================================================== */

static os_log_t sLog = NULL;

#define VLog(fmt, ...) os_log(sLog, fmt, ##__VA_ARGS__)
#define VLogError(fmt, ...) os_log_error(sLog, fmt, ##__VA_ARGS__)

/* ========================================================================== */
#pragma mark - Lock-free SPSC Ring Buffer
/* ========================================================================== */

/*
 * Lock-free SPSC ring buffer view for Float32 samples.
 *
 * This is a "view" into a buffer that may live in shared memory. The buffer
 * pointer and atomic cursors point into a VortexSharedAudioState region
 * (or into a locally-allocated fallback). The ring buffer does NOT own the
 * storage -- it is the caller's responsibility to set up the pointers.
 *
 * The capacity is always a power of two so index wrapping uses bitwise AND.
 * Cursor semantics: monotonically increasing sample counts with
 * acquire/release ordering.
 */
typedef struct {
    float*                      buffer;       /* sample storage (not owned) */
    uint32_t                    capacity;     /* always power-of-two */
    uint32_t                    mask;         /* capacity - 1 */
    _Atomic(uint64_t)*          writePos;     /* pointer to producer cursor */
    _Atomic(uint64_t)*          readPos;      /* pointer to consumer cursor */
} VortexRingBuffer;

/*
 * Initialize a ring buffer view over externally-owned storage.
 * `sampleBuffer` and the atomic pointers must remain valid for the ring's
 * lifetime. The caller is responsible for zeroing the buffer and cursors.
 */
static void
VortexRingBuffer_InitView(VortexRingBuffer* rb, uint32_t sampleCapacity,
                          float* sampleBuffer,
                          _Atomic(uint64_t)* writePos,
                          _Atomic(uint64_t)* readPos)
{
    rb->capacity = sampleCapacity;
    rb->mask = sampleCapacity - 1;
    rb->buffer = sampleBuffer;
    rb->writePos = writePos;
    rb->readPos = readPos;
}

/*
 * Tear down the ring buffer view. Does NOT free the backing storage
 * (which lives in shared memory or is owned by the caller).
 */
static void
VortexRingBuffer_Destroy(VortexRingBuffer* rb)
{
    rb->buffer = NULL;
    rb->writePos = NULL;
    rb->readPos = NULL;
}

/* Returns number of samples available for reading. */
static inline uint32_t
VortexRingBuffer_AvailableRead(const VortexRingBuffer* rb)
{
    uint64_t w = atomic_load_explicit(rb->writePos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(rb->readPos, memory_order_relaxed);
    return (uint32_t)(w - r);
}

/* Returns number of samples that can be written. */
static inline uint32_t
VortexRingBuffer_AvailableWrite(const VortexRingBuffer* rb)
{
    return rb->capacity - VortexRingBuffer_AvailableRead(rb);
}

/*
 * Write `count` samples from `src` into the ring buffer.
 * Returns the number of samples actually written.
 * RT-safe: no allocation, no locks, no syscalls.
 */
static uint32_t
VortexRingBuffer_Write(VortexRingBuffer* rb, const float* src, uint32_t count)
{
    uint32_t avail = VortexRingBuffer_AvailableWrite(rb);
    if (count > avail) count = avail;
    if (count == 0) return 0;

    uint64_t w = atomic_load_explicit(rb->writePos, memory_order_relaxed);
    uint32_t startIdx = (uint32_t)(w & rb->mask);
    uint32_t firstChunk = rb->capacity - startIdx;
    if (firstChunk > count) firstChunk = count;
    uint32_t secondChunk = count - firstChunk;

    memcpy(rb->buffer + startIdx, src, firstChunk * sizeof(float));
    if (secondChunk > 0) {
        memcpy(rb->buffer, src + firstChunk, secondChunk * sizeof(float));
    }

    atomic_store_explicit(rb->writePos, w + count, memory_order_release);
    return count;
}

/*
 * Read `count` samples from the ring buffer into `dst`.
 * Returns the number of samples actually read.
 * RT-safe: no allocation, no locks, no syscalls.
 */
static uint32_t
VortexRingBuffer_Read(VortexRingBuffer* rb, float* dst, uint32_t count)
{
    uint32_t avail = VortexRingBuffer_AvailableRead(rb);
    if (count > avail) count = avail;
    if (count == 0) return 0;

    uint64_t r = atomic_load_explicit(rb->readPos, memory_order_relaxed);
    uint32_t startIdx = (uint32_t)(r & rb->mask);
    uint32_t firstChunk = rb->capacity - startIdx;
    if (firstChunk > count) firstChunk = count;
    uint32_t secondChunk = count - firstChunk;

    memcpy(dst, rb->buffer + startIdx, firstChunk * sizeof(float));
    if (secondChunk > 0) {
        memcpy(dst + firstChunk, rb->buffer, secondChunk * sizeof(float));
    }

    atomic_store_explicit(rb->readPos, r + count, memory_order_release);
    return count;
}

static void
VortexRingBuffer_Reset(VortexRingBuffer* rb)
{
    atomic_store_explicit(rb->writePos, 0, memory_order_release);
    atomic_store_explicit(rb->readPos, 0, memory_order_release);
}

/* ========================================================================== */
#pragma mark - Driver State
/* ========================================================================== */

/*
 * All mutable driver state lives in a single struct. A single global instance
 * is allocated at plugin creation time and freed on final release.
 */
typedef struct {
    /*
     * COM / IUnknown layout:
     *   The first field is an AudioServerPlugInDriverInterface* that points
     *   to the vtable (which is the second field). The factory function
     *   returns &interface (i.e. an AudioServerPlugInDriverInterface**),
     *   which is the AudioServerPlugInDriverRef the host expects.
     */
    AudioServerPlugInDriverInterface*   interface;     /* -> vtable below */
    AudioServerPlugInDriverInterface    vtable;
    _Atomic(UInt32)                     refCount;

    /* Host interface, set during Initialize */
    AudioServerPlugInHostRef            host;

    /* Device state */
    _Atomic(uint64_t)                   sampleRateBits;   /* Float64 via bit-cast; use helpers below */
    UInt32                              ioBufferFrameSize;
    _Atomic(bool)                       ioIsRunning;
    _Atomic(UInt32)                     ioClientCount;  /* number of active IO clients */

    /* Clock state -- accessed from RT thread */
    _Atomic(Float64)                    hostTicksPerFrame;
    _Atomic(UInt64)                     anchorHostTime;    /* mach_absolute_time at start */
    _Atomic(Float64)                    anchorSampleTime;  /* sample time at anchor */
    _Atomic(UInt32)                     clockSeed;         /* incremented on clock discontinuity */

    /* Ring buffers for IO data -- views into shared memory */
    VortexRingBuffer                    outputRing;   /* apps -> plugin (WriteMix) */
    VortexRingBuffer                    inputRing;    /* plugin -> apps (ReadInput) */

    /* Shared memory state -- mapped via shm_open/mmap */
    VortexSharedAudioState*             sharedState;   /* NULL until shm is set up */
    int                                 shmFD;         /* shm file descriptor (-1 if closed) */

    /* Cached mach timebase for host-tick conversions. */
    Float64                             hostTicksPerSecond;
} VortexDriverState;

/* The one and only instance. */
static VortexDriverState* sDriver = NULL;

/*
 * Atomic sample-rate accessors.
 *
 * Float64 is NOT guaranteed atomic on ARM64 (the ISA only guarantees
 * atomic loads/stores for naturally-aligned integer types up to 64 bits).
 * We bit-cast the Float64 to/from a uint64_t and use C11 atomics with
 * explicit memory ordering to eliminate torn-read risk.
 */
static inline void
VortexAudio_StoreSampleRate(VortexDriverState* s, Float64 rate)
{
    uint64_t bits;
    memcpy(&bits, &rate, sizeof(bits));
    atomic_store_explicit(&s->sampleRateBits, bits, memory_order_release);
}

static inline Float64
VortexAudio_LoadSampleRate(VortexDriverState* s)
{
    uint64_t bits = atomic_load_explicit(&s->sampleRateBits, memory_order_acquire);
    Float64 rate;
    memcpy(&rate, &bits, sizeof(rate));
    return rate;
}

/* Forward declarations of all vtable methods. */
static HRESULT  VortexAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    VortexAudio_AddRef(void* inDriver);
static ULONG    VortexAudio_Release(void* inDriver);
static OSStatus VortexAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus VortexAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus VortexAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus VortexAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus VortexAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus VortexAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus VortexAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  VortexAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress);
static OSStatus VortexAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus VortexAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus VortexAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus VortexAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus VortexAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus VortexAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus VortexAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus VortexAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus VortexAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus VortexAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus VortexAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

/* ========================================================================== */
#pragma mark - Helpers
/* ========================================================================== */

/* Build a standard AudioStreamBasicDescription for our format. */
static AudioStreamBasicDescription
VortexAudio_MakeStreamFormat(Float64 sampleRate)
{
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate       = sampleRate;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat
                          | kAudioFormatFlagsNativeEndian
                          | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel   = kVortexBitsPerChannel;
    fmt.mChannelsPerFrame = kVortexNumChannels;
    fmt.mBytesPerFrame    = kVortexBytesPerFrame;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = kVortexBytesPerFrame;
    return fmt;
}

/* Compute mach ticks per second from the timebase info. */
static Float64
VortexAudio_HostTicksPerSecond(void)
{
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    /* info gives nanoseconds = ticks * numer / denom */
    /* ticks per second = 1e9 * denom / numer */
    return (1000000000.0 * (Float64)info.denom) / (Float64)info.numer;
}

/* ========================================================================== */
#pragma mark - COM / IUnknown
/* ========================================================================== */

static HRESULT
VortexAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    /* We only support the AudioServerPlugIn driver interface and IUnknown. */
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (requestedUUID == NULL) {
        if (outInterface) *outInterface = NULL;
        return E_NOINTERFACE;
    }

    CFUUIDRef driverUUID = kAudioServerPlugInDriverInterfaceUUID;
    CFUUIDRef iunknownUUID = CFUUIDGetConstantUUIDWithBytes(NULL,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46); /* IUnknown */

    if (CFEqual(requestedUUID, driverUUID) || CFEqual(requestedUUID, iunknownUUID)) {
        CFRelease(requestedUUID);
        VortexAudio_AddRef(inDriver);
        *outInterface = inDriver;
        return S_OK;
    }

    CFRelease(requestedUUID);
    if (outInterface) *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG
VortexAudio_AddRef(void* inDriver)
{
    /*
     * inDriver is &state->interface, and interface is the first field of
     * VortexDriverState, so the address of the struct equals inDriver.
     */
    VortexDriverState* state = (VortexDriverState*)inDriver;
    if (state != sDriver) return 0;
    UInt32 newCount = atomic_fetch_add_explicit(&state->refCount, 1, memory_order_relaxed) + 1;
    return (ULONG)newCount;
}

static ULONG
VortexAudio_Release(void* inDriver)
{
    VortexDriverState* state = (VortexDriverState*)inDriver;
    if (state != sDriver) return 0;
    UInt32 oldCount = atomic_fetch_sub_explicit(&state->refCount, 1, memory_order_acq_rel);
    UInt32 newCount = oldCount - 1;
    if (newCount == 0) {
        VortexRingBuffer_Destroy(&state->outputRing);
        VortexRingBuffer_Destroy(&state->inputRing);
        /* Unmap and unlink shared memory. */
        if (state->sharedState != NULL) {
            munmap(state->sharedState, VORTEX_SHM_SIZE);
            state->sharedState = NULL;
        }
        if (state->shmFD >= 0) {
            close(state->shmFD);
            state->shmFD = -1;
        }
        shm_unlink(VORTEX_SHM_NAME);
        free(state);
        sDriver = NULL;
    }
    return (ULONG)newCount;
}

/* ========================================================================== */
#pragma mark - Factory
/* ========================================================================== */

/*
 * VortexAudio_Create -- CFPlugIn factory function.
 *
 * Called by the audio server when loading the plugin. We verify the requested
 * type UUID matches kAudioServerPlugInTypeUUID, allocate and initialize the
 * driver singleton, and return a pointer to its COM interface.
 */
__attribute__((visibility("default")))
void*
VortexAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;

    /* Only create for the AudioServerPlugIn type. */
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    /* Initialize logging. */
    if (sLog == NULL) {
        sLog = os_log_create("com.vortex.audio.plugin", "Driver");
    }

    VLog("VortexAudio_Create: initializing driver");

    /* Allocate the driver state. */
    VortexDriverState* state = (VortexDriverState*)calloc(1, sizeof(VortexDriverState));
    if (state == NULL) {
        VLogError("VortexAudio_Create: failed to allocate driver state");
        return NULL;
    }

    /* Populate the vtable. */
    state->vtable._reserved                         = NULL;
    state->vtable.QueryInterface                     = VortexAudio_QueryInterface;
    state->vtable.AddRef                             = VortexAudio_AddRef;
    state->vtable.Release                            = VortexAudio_Release;
    state->vtable.Initialize                         = VortexAudio_Initialize;
    state->vtable.CreateDevice                       = VortexAudio_CreateDevice;
    state->vtable.DestroyDevice                      = VortexAudio_DestroyDevice;
    state->vtable.AddDeviceClient                    = VortexAudio_AddDeviceClient;
    state->vtable.RemoveDeviceClient                 = VortexAudio_RemoveDeviceClient;
    state->vtable.PerformDeviceConfigurationChange   = VortexAudio_PerformDeviceConfigurationChange;
    state->vtable.AbortDeviceConfigurationChange     = VortexAudio_AbortDeviceConfigurationChange;
    state->vtable.HasProperty                        = VortexAudio_HasProperty;
    state->vtable.IsPropertySettable                 = VortexAudio_IsPropertySettable;
    state->vtable.GetPropertyDataSize                = VortexAudio_GetPropertyDataSize;
    state->vtable.GetPropertyData                    = VortexAudio_GetPropertyData;
    state->vtable.SetPropertyData                    = VortexAudio_SetPropertyData;
    state->vtable.StartIO                            = VortexAudio_StartIO;
    state->vtable.StopIO                             = VortexAudio_StopIO;
    state->vtable.GetZeroTimeStamp                   = VortexAudio_GetZeroTimeStamp;
    state->vtable.WillDoIOOperation                  = VortexAudio_WillDoIOOperation;
    state->vtable.BeginIOOperation                   = VortexAudio_BeginIOOperation;
    state->vtable.DoIOOperation                      = VortexAudio_DoIOOperation;
    state->vtable.EndIOOperation                     = VortexAudio_EndIOOperation;

    /* Set up the COM self-reference: interface -> vtable. */
    state->interface = &state->vtable;

    /* Initial state. */
    atomic_store_explicit(&state->refCount, 1, memory_order_relaxed);
    state->host                 = NULL;
    VortexAudio_StoreSampleRate(state, kVortexDefaultSampleRate);
    state->ioBufferFrameSize    = kDefaultIOBufferFrames;
    atomic_store_explicit(&state->ioIsRunning, false, memory_order_relaxed);
    atomic_store_explicit(&state->ioClientCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->clockSeed, 1, memory_order_relaxed);
    atomic_store_explicit(&state->anchorHostTime, 0, memory_order_relaxed);
    atomic_store_explicit(&state->anchorSampleTime, 0.0, memory_order_relaxed);

    /* Compute timing constants. */
    state->hostTicksPerSecond = VortexAudio_HostTicksPerSecond();
    Float64 tpf = state->hostTicksPerSecond / VortexAudio_LoadSampleRate(state);
    atomic_store_explicit(&state->hostTicksPerFrame, tpf, memory_order_relaxed);

    /*
     * Create POSIX shared memory for the ring buffers.
     * The HAL plugin owns the segment (O_CREAT). The daemon opens it later.
     *
     * If coreaudiod restarts, VortexAudio_Create is called again. Handle
     * re-creation gracefully:
     *   1. Try O_CREAT | O_EXCL first (brand new segment).
     *   2. If EEXIST, the segment already exists from a prior instance.
     *      Open with O_CREAT (no EXCL), re-map, and reset all positions.
     *   3. Increment the generation counter so the daemon detects the re-sync.
     */
    uint32_t prevGeneration = 0;
    bool isRecreation = false;

    int shmFD = shm_open(VORTEX_SHM_NAME, O_CREAT | O_EXCL | O_RDWR, 0666);
    if (shmFD < 0 && errno == EEXIST) {
        /* Segment exists from a prior plugin instance. Re-open it. */
        shmFD = shm_open(VORTEX_SHM_NAME, O_RDWR, 0666);
        if (shmFD >= 0) {
            /*
             * Try to read the previous generation from the existing segment
             * before we zero it out. Map read-only first to peek at it.
             */
            void* peek = mmap(NULL, VORTEX_SHM_SIZE,
                              PROT_READ, MAP_SHARED, shmFD, 0);
            if (peek != MAP_FAILED) {
                VortexSharedAudioState* old = (VortexSharedAudioState*)peek;
                uint32_t oldMagic = atomic_load_explicit(&old->magic, memory_order_acquire);
                if (oldMagic == VORTEX_SHM_MAGIC) {
                    prevGeneration = atomic_load_explicit(&old->generation, memory_order_acquire);
                }
                munmap(peek, VORTEX_SHM_SIZE);
            }
            isRecreation = true;
            VLog("VortexAudio_Create: shm segment already exists -- re-creating (prev gen %u)", prevGeneration);
        }
    }
    if (shmFD < 0) {
        VLogError("VortexAudio_Create: shm_open failed (errno %d)", errno);
        free(state);
        return NULL;
    }

    if (ftruncate(shmFD, (off_t)VORTEX_SHM_SIZE) != 0) {
        VLogError("VortexAudio_Create: ftruncate failed (errno %d)", errno);
        close(shmFD);
        if (!isRecreation) shm_unlink(VORTEX_SHM_NAME);
        free(state);
        return NULL;
    }

    void* mapped = mmap(NULL, VORTEX_SHM_SIZE,
                        PROT_READ | PROT_WRITE, MAP_SHARED, shmFD, 0);
    if (mapped == MAP_FAILED) {
        VLogError("VortexAudio_Create: mmap failed (errno %d)", errno);
        close(shmFD);
        if (!isRecreation) shm_unlink(VORTEX_SHM_NAME);
        free(state);
        return NULL;
    }

    /* Zero the entire region and initialize the header.
     * On re-creation this resets all ring positions to 0. */
    memset(mapped, 0, VORTEX_SHM_SIZE);

    /* Pin pages to prevent page faults on the RT audio thread. */
    if (mlock(mapped, VORTEX_SHM_SIZE) != 0) {
        VLog("VortexAudio_Create: mlock failed (errno %d) -- pages may fault on RT thread", errno);
    }

    VortexSharedAudioState* shared = (VortexSharedAudioState*)mapped;
    atomic_store_explicit(&shared->magic, VORTEX_SHM_MAGIC, memory_order_release);
    atomic_store_explicit(&shared->version, VORTEX_SHM_VERSION, memory_order_release);
    atomic_store_explicit(&shared->sampleRate, (uint32_t)VortexAudio_LoadSampleRate(state), memory_order_release);
    atomic_store_explicit(&shared->channels, kVortexNumChannels, memory_order_release);
    atomic_store_explicit(&shared->isActive, 0, memory_order_release);

    /* Increment generation so the daemon detects the re-creation and re-syncs. */
    atomic_store_explicit(&shared->generation, prevGeneration + 1, memory_order_release);

    state->sharedState = shared;
    state->shmFD = shmFD;

    /* Set up ring buffer views pointing into the shared memory region. */
    VortexRingBuffer_InitView(&state->outputRing, kRingBufferSampleCapacity,
                              shared->outputBuffer,
                              &shared->outputWritePos,
                              &shared->outputReadPos);

    VortexRingBuffer_InitView(&state->inputRing, kRingBufferSampleCapacity,
                              shared->inputBuffer,
                              &shared->inputWritePos,
                              &shared->inputReadPos);

    VLog("VortexAudio_Create: shared memory '%s' %s (gen %u, %zu bytes)",
         VORTEX_SHM_NAME, isRecreation ? "re-created" : "created",
         prevGeneration + 1, (size_t)VORTEX_SHM_SIZE);

    sDriver = state;

    VLog("VortexAudio_Create: driver created successfully");
    return &state->interface;
}

/* ========================================================================== */
#pragma mark - Driver Lifecycle
/* ========================================================================== */

static OSStatus
VortexAudio_Initialize(AudioServerPlugInDriverRef inDriver,
                       AudioServerPlugInHostRef inHost)
{
    VortexDriverState* state = sDriver;
    if (state == NULL || inDriver != &state->interface) {
        return kAudioHardwareBadObjectError;
    }

    state->host = inHost;

    VLog("VortexAudio_Initialize: host interface stored");
    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_CreateDevice(AudioServerPlugInDriverRef inDriver,
                         CFDictionaryRef inDescription,
                         const AudioServerPlugInClientInfo* inClientInfo,
                         AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    /* We do not support dynamic device creation. */
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
VortexAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                          AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
VortexAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID,
                            const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    /* Nothing to track per-client for now. */
    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inDeviceObjectID,
                               const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt64 inChangeAction,
                                             void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    /* Configuration changes (sample rate) are applied in SetPropertyData, then
       the host calls this to confirm. Nothing extra to do. */
    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           UInt64 inChangeAction,
                                           void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

/* ========================================================================== */
#pragma mark - Property: HasProperty
/* ========================================================================== */

static Boolean
VortexAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                        AudioObjectID inObjectID,
                        pid_t inClientPID,
                        const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientPID;

    switch (inObjectID) {

    /* ---- Plugin object ---- */
    case kAudioObjectPlugInObject:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
        }

    /* ---- Device object ---- */
    case kVortexDeviceID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        default:
            return false;
        }

    /* ---- Output stream ---- */
    case kVortexOutputStreamID:
    /* ---- Input stream ---- */
    case kVortexInputStreamID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
        }

    default:
        return false;
    }
}

/* ========================================================================== */
#pragma mark - Property: IsPropertySettable
/* ========================================================================== */

static OSStatus
VortexAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inObjectID,
                               pid_t inClientPID,
                               const AudioObjectPropertyAddress* inAddress,
                               Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientPID;

    if (!VortexAudio_HasProperty(inDriver, inObjectID, inClientPID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    /* By default, properties are not settable. */
    *outIsSettable = false;

    if (inObjectID == kVortexDeviceID) {
        switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            *outIsSettable = true;
            break;
        default:
            break;
        }
    }
    else if (inObjectID == kVortexOutputStreamID || inObjectID == kVortexInputStreamID) {
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;
        default:
            break;
        }
    }

    return kAudioHardwareNoError;
}

/* ========================================================================== */
#pragma mark - Property: GetPropertyDataSize
/* ========================================================================== */

static OSStatus
VortexAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientPID,
                                const AudioObjectPropertyAddress* inAddress,
                                UInt32 inQualifierDataSize,
                                const void* inQualifierData,
                                UInt32* outDataSize)
{
    (void)inDriver; (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;

    if (!VortexAudio_HasProperty(inDriver, inObjectID, inClientPID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {

    /* ---- Plugin ---- */
    case kAudioObjectPlugInObject:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID); /* one device */
            break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            break;
        default:
            *outDataSize = 0;
            break;
        }
        break;

    /* ---- Device ---- */
    case kVortexDeviceID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyStreams: {
            /* Return streams for the requested scope. */
            UInt32 count = 0;
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                count = 2; /* output + input */
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                count = 1;
            } else if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                count = 1;
            }
            *outDataSize = count * (UInt32)sizeof(AudioObjectID);
            break;
        }
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 2 * (UInt32)sizeof(AudioObjectID); /* two streams */
            break;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0; /* no controls */
            break;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            break;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)(kNumSupportedSampleRates * sizeof(AudioValueRange));
            break;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * (UInt32)sizeof(UInt32);
            break;
        default:
            *outDataSize = 0;
            break;
        }
        break;

    /* ---- Streams ---- */
    case kVortexOutputStreamID:
    case kVortexInputStreamID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = (UInt32)(kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription));
            break;
        default:
            *outDataSize = 0;
            break;
        }
        break;

    default:
        return kAudioHardwareBadObjectError;
    }

    return kAudioHardwareNoError;
}

/* ========================================================================== */
#pragma mark - Property: GetPropertyData
/* ========================================================================== */

/*
 * Helper to write a value into the output buffer with size checking.
 * Sets *outDataSize to the number of bytes written.
 */
#define WRITE_PROPERTY(type, value) do {                        \
    if (inDataSize < (UInt32)sizeof(type))                      \
        return kAudioHardwareBadPropertySizeError;              \
    *((type*)outData) = (value);                                \
    *outDataSize = (UInt32)sizeof(type);                        \
} while (0)

#define WRITE_CFSTRING(str) do {                                \
    if (inDataSize < (UInt32)sizeof(CFStringRef))               \
        return kAudioHardwareBadPropertySizeError;              \
    *((CFStringRef*)outData) = (str);                           \
    *outDataSize = (UInt32)sizeof(CFStringRef);                 \
} while (0)

static OSStatus
VortexAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inObjectID,
                            pid_t inClientPID,
                            const AudioObjectPropertyAddress* inAddress,
                            UInt32 inQualifierDataSize,
                            const void* inQualifierData,
                            UInt32 inDataSize,
                            UInt32* outDataSize,
                            void* outData)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;

    VortexDriverState* state = sDriver;
    if (state == NULL || inDriver != &state->interface) {
        return kAudioHardwareBadObjectError;
    }

    if (!VortexAudio_HasProperty(inDriver, inObjectID, inClientPID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {

    /* ==== Plugin object ==== */
    case kAudioObjectPlugInObject:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            WRITE_PROPERTY(AudioClassID, kAudioObjectClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            WRITE_PROPERTY(AudioClassID, kAudioPlugInClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            WRITE_PROPERTY(AudioObjectID, kAudioObjectUnknown);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            WRITE_CFSTRING(CFSTR(kVortexManufacturer));
            return kAudioHardwareNoError;

        case kAudioPlugInPropertyBundleID:
            WRITE_CFSTRING(CFSTR(kVortexBundleID));
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            if (inDataSize < sizeof(AudioObjectID))
                return kAudioHardwareBadPropertySizeError;
            UInt32 count = inDataSize / (UInt32)sizeof(AudioObjectID);
            if (count > 1) count = 1;
            ((AudioObjectID*)outData)[0] = kVortexDeviceID;
            *outDataSize = count * (UInt32)sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            /* Qualifier is a CFStringRef with the UID to look up. */
            AudioObjectID result = kAudioObjectUnknown;
            if (inQualifierDataSize >= sizeof(CFStringRef) && inQualifierData != NULL) {
                CFStringRef uid = *((const CFStringRef*)inQualifierData);
                if (uid != NULL && CFEqual(uid, CFSTR(kVortexDeviceUID))) {
                    result = kVortexDeviceID;
                }
            }
            WRITE_PROPERTY(AudioObjectID, result);
            return kAudioHardwareNoError;
        }

        case kAudioPlugInPropertyResourceBundle:
            WRITE_CFSTRING(CFSTR(""));
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
        }

    /* ==== Device object ==== */
    case kVortexDeviceID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            WRITE_PROPERTY(AudioClassID, kAudioObjectClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            WRITE_PROPERTY(AudioClassID, kAudioDeviceClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            WRITE_PROPERTY(AudioObjectID, kAudioObjectPlugInObject);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyName:
            WRITE_CFSTRING(CFSTR(kVortexDeviceName));
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            WRITE_CFSTRING(CFSTR(kVortexManufacturer));
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceUID:
            WRITE_CFSTRING(CFSTR(kVortexDeviceUID));
            return kAudioHardwareNoError;

        case kAudioDevicePropertyModelUID:
            WRITE_CFSTRING(CFSTR(kVortexModelUID));
            return kAudioHardwareNoError;

        case kAudioDevicePropertyTransportType:
            WRITE_PROPERTY(UInt32, kAudioDeviceTransportTypeVirtual);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyRelatedDevices: {
            if (inDataSize < sizeof(AudioObjectID))
                return kAudioHardwareBadPropertySizeError;
            ((AudioObjectID*)outData)[0] = kVortexDeviceID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyClockDomain:
            WRITE_PROPERTY(UInt32, 0);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceIsAlive:
            WRITE_PROPERTY(UInt32, 1);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceIsRunning:
            WRITE_PROPERTY(UInt32, atomic_load_explicit(&state->ioIsRunning, memory_order_acquire) ? 1 : 0);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            WRITE_PROPERTY(UInt32, 1);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            WRITE_PROPERTY(UInt32, 1);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyLatency:
            WRITE_PROPERTY(UInt32, 0);
            return kAudioHardwareNoError;

        case kAudioDevicePropertySafetyOffset:
            WRITE_PROPERTY(UInt32, 0);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyIsHidden:
            WRITE_PROPERTY(UInt32, 0);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            WRITE_PROPERTY(UInt32, kZeroTimestampPeriod);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyStreams: {
            UInt32 maxItems = inDataSize / (UInt32)sizeof(AudioObjectID);
            AudioObjectID* ids = (AudioObjectID*)outData;
            UInt32 count = 0;

            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                if (count < maxItems) ids[count++] = kVortexOutputStreamID;
                if (count < maxItems) ids[count++] = kVortexInputStreamID;
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                if (count < maxItems) ids[count++] = kVortexOutputStreamID;
            } else if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                if (count < maxItems) ids[count++] = kVortexInputStreamID;
            }

            *outDataSize = count * (UInt32)sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyOwnedObjects: {
            UInt32 maxItems = inDataSize / (UInt32)sizeof(AudioObjectID);
            AudioObjectID* ids = (AudioObjectID*)outData;
            UInt32 count = 0;
            if (count < maxItems) ids[count++] = kVortexOutputStreamID;
            if (count < maxItems) ids[count++] = kVortexInputStreamID;
            *outDataSize = count * (UInt32)sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyNominalSampleRate:
            WRITE_PROPERTY(Float64, VortexAudio_LoadSampleRate(state));
            return kAudioHardwareNoError;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 maxItems = inDataSize / (UInt32)sizeof(AudioValueRange);
            UInt32 count = (UInt32)kNumSupportedSampleRates;
            if (count > maxItems) count = maxItems;
            AudioValueRange* ranges = (AudioValueRange*)outData;
            for (UInt32 i = 0; i < count; i++) {
                ranges[i].mMinimum = kSupportedSampleRates[i];
                ranges[i].mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = count * (UInt32)sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32))
                return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; /* left */
            ((UInt32*)outData)[1] = 2; /* right */
            *outDataSize = 2 * (UInt32)sizeof(UInt32);
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
        }

    /* ==== Stream objects ==== */
    case kVortexOutputStreamID:
    case kVortexInputStreamID: {
        Boolean isOutput = (inObjectID == kVortexOutputStreamID);

        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            WRITE_PROPERTY(AudioClassID, kAudioObjectClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            WRITE_PROPERTY(AudioClassID, kAudioStreamClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            WRITE_PROPERTY(AudioObjectID, kVortexDeviceID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyName:
            WRITE_CFSTRING(isOutput ? CFSTR("Output") : CFSTR("Input"));
            return kAudioHardwareNoError;

        case kAudioStreamPropertyIsActive:
            WRITE_PROPERTY(UInt32, 1);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyDirection:
            /* 0 = output, 1 = input */
            WRITE_PROPERTY(UInt32, isOutput ? 0 : 1);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyTerminalType:
            WRITE_PROPERTY(UInt32, isOutput ? kAudioStreamTerminalTypeSpeaker : kAudioStreamTerminalTypeMicrophone);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyStartingChannel:
            WRITE_PROPERTY(UInt32, 1);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyLatency:
            WRITE_PROPERTY(UInt32, 0);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize < sizeof(AudioStreamBasicDescription))
                return kAudioHardwareBadPropertySizeError;
            AudioStreamBasicDescription fmt = VortexAudio_MakeStreamFormat(VortexAudio_LoadSampleRate(state));
            *((AudioStreamBasicDescription*)outData) = fmt;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 maxItems = inDataSize / (UInt32)sizeof(AudioStreamRangedDescription);
            UInt32 count = (UInt32)kNumSupportedSampleRates;
            if (count > maxItems) count = maxItems;
            AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
            for (UInt32 i = 0; i < count; i++) {
                descs[i].mFormat = VortexAudio_MakeStreamFormat(kSupportedSampleRates[i]);
                descs[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                descs[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = count * (UInt32)sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
        }
    }

    default:
        return kAudioHardwareBadObjectError;
    }
}

/* ========================================================================== */
#pragma mark - Property: SetPropertyData
/* ========================================================================== */

static OSStatus
VortexAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inObjectID,
                            pid_t inClientPID,
                            const AudioObjectPropertyAddress* inAddress,
                            UInt32 inQualifierDataSize,
                            const void* inQualifierData,
                            UInt32 inDataSize,
                            const void* inData)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;

    VortexDriverState* state = sDriver;
    if (state == NULL || inDriver != &state->interface) {
        return kAudioHardwareBadObjectError;
    }

    if (inObjectID == kVortexDeviceID &&
        inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
    {
        if (inDataSize < sizeof(Float64))
            return kAudioHardwareBadPropertySizeError;

        Float64 newRate = *((const Float64*)inData);

        /* Validate the requested rate. */
        bool valid = false;
        for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
            if (kSupportedSampleRates[i] == newRate) {
                valid = true;
                break;
            }
        }
        if (!valid) return kAudioDeviceUnsupportedFormatError;

        if (newRate != VortexAudio_LoadSampleRate(state)) {
            /*
             * Request a configuration change through the host so it can stop
             * IO and prepare for the rate change. We pass the new rate as the
             * change action (cast to UInt64 bits).
             */
            if (state->host != NULL) {
                UInt64 action;
                memcpy(&action, &newRate, sizeof(action));
                state->host->RequestDeviceConfigurationChange(
                    state->host, kVortexDeviceID, action, NULL);
            }

            /* Apply the new rate. */
            VortexAudio_StoreSampleRate(state, newRate);
            Float64 tpf = state->hostTicksPerSecond / newRate;
            atomic_store_explicit(&state->hostTicksPerFrame, tpf, memory_order_release);

            /* Propagate to shared memory so the daemon picks up the change. */
            if (state->sharedState != NULL) {
                atomic_store_explicit(&state->sharedState->sampleRate,
                                      (uint32_t)newRate, memory_order_release);
            }

            /* Bump the clock seed so clients know the timeline changed. */
            atomic_fetch_add_explicit(&state->clockSeed, 1, memory_order_release);
        }

        return kAudioHardwareNoError;
    }

    if ((inObjectID == kVortexOutputStreamID || inObjectID == kVortexInputStreamID) &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
         inAddress->mSelector == kAudioStreamPropertyPhysicalFormat))
    {
        if (inDataSize < sizeof(AudioStreamBasicDescription))
            return kAudioHardwareBadPropertySizeError;

        const AudioStreamBasicDescription* newFmt = (const AudioStreamBasicDescription*)inData;

        /* We only accept our own format with a supported sample rate. */
        if (newFmt->mFormatID != kAudioFormatLinearPCM)
            return kAudioDeviceUnsupportedFormatError;
        if (newFmt->mChannelsPerFrame != kVortexNumChannels)
            return kAudioDeviceUnsupportedFormatError;
        if (!(newFmt->mFormatFlags & kAudioFormatFlagIsFloat))
            return kAudioDeviceUnsupportedFormatError;
        if (newFmt->mBitsPerChannel != kVortexBitsPerChannel)
            return kAudioDeviceUnsupportedFormatError;

        /* Validate sample rate. */
        bool valid = false;
        for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
            if (kSupportedSampleRates[i] == newFmt->mSampleRate) {
                valid = true;
                break;
            }
        }
        if (!valid) return kAudioDeviceUnsupportedFormatError;

        /* If sample rate changed, apply it. */
        if (newFmt->mSampleRate != VortexAudio_LoadSampleRate(state)) {
            VortexAudio_StoreSampleRate(state, newFmt->mSampleRate);
            Float64 tpf = state->hostTicksPerSecond / newFmt->mSampleRate;
            atomic_store_explicit(&state->hostTicksPerFrame, tpf, memory_order_release);
            if (state->sharedState != NULL) {
                atomic_store_explicit(&state->sharedState->sampleRate,
                                      (uint32_t)newFmt->mSampleRate, memory_order_release);
            }
            atomic_fetch_add_explicit(&state->clockSeed, 1, memory_order_release);
        }

        return kAudioHardwareNoError;
    }

    return kAudioHardwareUnsupportedOperationError;
}

/* ========================================================================== */
#pragma mark - IO Operations
/* ========================================================================== */

static OSStatus
VortexAudio_StartIO(AudioServerPlugInDriverRef inDriver,
                    AudioObjectID inDeviceObjectID,
                    UInt32 inClientID)
{
    (void)inClientID;

    VortexDriverState* state = sDriver;
    if (state == NULL || inDriver != &state->interface) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kVortexDeviceID) {
        return kAudioHardwareBadDeviceError;
    }

    UInt32 prev = atomic_fetch_add_explicit(&state->ioClientCount, 1, memory_order_acq_rel);
    if (prev == 0) {
        /* First client starting IO: anchor the clock. */
        VortexRingBuffer_Reset(&state->outputRing);
        VortexRingBuffer_Reset(&state->inputRing);
        atomic_store_explicit(&state->anchorHostTime, mach_absolute_time(), memory_order_release);
        atomic_store_explicit(&state->anchorSampleTime, 0.0, memory_order_release);
        atomic_store_explicit(&state->ioIsRunning, true, memory_order_release);
        /* Signal the daemon that IO is active. */
        if (state->sharedState != NULL) {
            atomic_store_explicit(&state->sharedState->sampleRate,
                                  (uint32_t)VortexAudio_LoadSampleRate(state), memory_order_release);
            atomic_store_explicit(&state->sharedState->isActive, 1, memory_order_release);
        }
        VLog("VortexAudio_StartIO: IO started (client %u)", inClientID);
    }

    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_StopIO(AudioServerPlugInDriverRef inDriver,
                   AudioObjectID inDeviceObjectID,
                   UInt32 inClientID)
{
    (void)inClientID;

    VortexDriverState* state = sDriver;
    if (state == NULL || inDriver != &state->interface) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kVortexDeviceID) {
        return kAudioHardwareBadDeviceError;
    }

    /* Guard against underflow: if ioClientCount is already 0, a spurious
     * StopIO has occurred. Log it and bail out without decrementing. */
    UInt32 expected = atomic_load_explicit(&state->ioClientCount, memory_order_acquire);
    if (expected == 0) {
        VLogError("VortexAudio_StopIO: ioClientCount already 0 -- spurious StopIO (client %u)", inClientID);
        return kAudioHardwareNotRunningError;
    }

    UInt32 prev = atomic_fetch_sub_explicit(&state->ioClientCount, 1, memory_order_acq_rel);
    if (prev == 1) {
        /* Last client stopped: IO is no longer running. */
        atomic_store_explicit(&state->ioIsRunning, false, memory_order_release);
        /* Signal the daemon that IO is inactive. */
        if (state->sharedState != NULL) {
            atomic_store_explicit(&state->sharedState->isActive, 0, memory_order_release);
        }
        VLog("VortexAudio_StopIO: IO stopped (client %u)", inClientID);
    }

    return kAudioHardwareNoError;
}

/*
 * GetZeroTimeStamp -- called on the RT thread every IO cycle.
 *
 * We synthesize a clock by computing what sample time the device "should" be
 * at based on wall-clock elapsed time since the anchor. We then quantize down
 * to the nearest multiple of kZeroTimestampPeriod and report the corresponding
 * host time.
 */
static OSStatus
VortexAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             UInt32 inClientID,
                             Float64* outSampleTime,
                             UInt64* outHostTime,
                             UInt64* outSeed)
{
    (void)inClientID;

    VortexDriverState* state = sDriver;
    if (state == NULL || inDriver != &state->interface) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kVortexDeviceID) {
        return kAudioHardwareBadDeviceError;
    }

    Float64 ticksPerFrame = atomic_load_explicit(&state->hostTicksPerFrame, memory_order_acquire);
    UInt64  anchorHost    = atomic_load_explicit(&state->anchorHostTime, memory_order_acquire);

    /* How many ticks have elapsed since the anchor? */
    UInt64  currentHost   = mach_absolute_time();
    Float64 elapsedTicks  = (Float64)(currentHost - anchorHost);
    Float64 elapsedFrames = elapsedTicks / ticksPerFrame;

    /* Quantize to the nearest preceding zero-timestamp boundary. */
    UInt64  periods       = (UInt64)(elapsedFrames / (Float64)kZeroTimestampPeriod);
    Float64 sampleTime    = (Float64)(periods * kZeroTimestampPeriod);
    UInt64  hostTime      = anchorHost + (UInt64)(sampleTime * ticksPerFrame);

    *outSampleTime = sampleTime;
    *outHostTime   = hostTime;
    *outSeed       = atomic_load_explicit(&state->clockSeed, memory_order_acquire);

    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID,
                              UInt32 inOperationID,
                              Boolean* outWillDo,
                              Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    *outWillDo = false;
    *outWillDoInPlace = true;

    switch (inOperationID) {
    case kAudioServerPlugInIOOperationReadInput:
        *outWillDo = true;
        *outWillDoInPlace = true;
        break;
    case kAudioServerPlugInIOOperationWriteMix:
        *outWillDo = true;
        *outWillDoInPlace = true;
        break;
    default:
        break;
    }

    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             UInt32 inClientID,
                             UInt32 inOperationID,
                             UInt32 inIOBufferFrameSize,
                             const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

/*
 * DoIOOperation -- the heart of the IO path. Runs on the RT thread.
 *
 * For WriteMix (output): the host has mixed all client output data into
 * ioMainBuffer. We copy it into the output ring buffer.
 *
 * For ReadInput (input): we fill ioMainBuffer from the input ring buffer.
 * If the ring buffer is empty (no data from vsock yet), we output silence.
 *
 * Both operations are fully RT-safe: memcpy and atomic ops only.
 */
static OSStatus
VortexAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                          AudioObjectID inDeviceObjectID,
                          AudioObjectID inStreamObjectID,
                          UInt32 inClientID,
                          UInt32 inOperationID,
                          UInt32 inIOBufferFrameSize,
                          const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                          void* ioMainBuffer,
                          void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    VortexDriverState* state = sDriver;
    if (state == NULL) return kAudioHardwareBadObjectError;

    uint32_t sampleCount = inIOBufferFrameSize * kVortexNumChannels;
    float* buffer = (float*)ioMainBuffer;

    switch (inOperationID) {
    case kAudioServerPlugInIOOperationWriteMix: {
        /*
         * Output path: apps have written mixed audio into ioMainBuffer.
         * Store it in the output ring for the vsock daemon to consume.
         */
        if (inStreamObjectID == kVortexOutputStreamID && buffer != NULL) {
            VortexRingBuffer_Write(&state->outputRing, buffer, sampleCount);
        }
        break;
    }

    case kAudioServerPlugInIOOperationReadInput: {
        /*
         * Input path: fill ioMainBuffer from the input ring buffer.
         * If not enough data is available, fill the remainder with silence.
         */
        if (inStreamObjectID == kVortexInputStreamID && buffer != NULL) {
            uint32_t read = VortexRingBuffer_Read(&state->inputRing, buffer, sampleCount);
            if (read < sampleCount) {
                memset(buffer + read, 0, (sampleCount - read) * sizeof(float));
            }
        }
        break;
    }

    default:
        break;
    }

    return kAudioHardwareNoError;
}

static OSStatus
VortexAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID,
                           UInt32 inClientID,
                           UInt32 inOperationID,
                           UInt32 inIOBufferFrameSize,
                           const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
