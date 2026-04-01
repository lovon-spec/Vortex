/*
 * VortexSharedAudio.h -- Shared memory layout for HAL plugin <-> daemon IPC.
 *
 * Both the HAL plugin (running in coreaudiod) and the VortexAudioDaemon
 * (running as a LaunchDaemon) mmap the same POSIX shared memory region.
 * This header defines the memory layout, ring buffer geometry, and the
 * atomic coordination protocol between the two processes.
 *
 * Ring buffer protocol (SPSC per direction):
 *   - Output ring: HAL plugin is the PRODUCER (WriteMix), daemon is CONSUMER.
 *   - Input ring:  Daemon is the PRODUCER, HAL plugin is CONSUMER (ReadInput).
 *   - Positions are monotonically increasing uint64_t counts of SAMPLES
 *     (not frames, not bytes). Index into the buffer via (pos & mask).
 *   - Producer: store_release on writePos after memcpy.
 *   - Consumer: load_acquire on writePos, store_release on readPos after memcpy.
 *   - Capacity MUST be a power of two so masking works.
 *
 * The HAL plugin creates the shm segment (O_CREAT) during Initialize.
 * The daemon opens it (O_RDWR, no O_CREAT) after startup.
 *
 * RT-safety: The HAL plugin's DoIOOperation accesses the ring buffers on a
 * real-time audio thread. The shared memory region is pre-faulted and locked.
 * All operations are memcpy + atomics only -- no allocations, no locks, no
 * syscalls on the RT path.
 *
 * Copyright 2024-2026 Vortex Authors. All rights reserved.
 * SPDX-License-Identifier: MIT
 */

#ifndef VORTEX_SHARED_AUDIO_H
#define VORTEX_SHARED_AUDIO_H

#include <stdatomic.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * POSIX shared memory name. Both plugin and daemon use this exact string
 * with shm_open(). The leading '/' is required by POSIX.
 */
#define VORTEX_SHM_NAME     "/vortex-audio"

/*
 * Ring buffer capacity in FRAMES (not samples, not bytes).
 * Must be a power of two. 65536 frames at 48 kHz = ~1.365 seconds of buffer,
 * which provides ample headroom for the vsock round-trip.
 */
#define VORTEX_RING_FRAMES  65536

/*
 * Maximum channel count. Fixed at stereo for now.
 */
#define VORTEX_MAX_CHANNELS 2

/*
 * Derived constants.
 * Sample capacity = frames * channels (all ring arithmetic is in samples).
 */
#define VORTEX_RING_SAMPLES (VORTEX_RING_FRAMES * VORTEX_MAX_CHANNELS)
#define VORTEX_RING_MASK    (VORTEX_RING_SAMPLES - 1)

/*
 * Magic value written to the header to verify the shm segment is valid.
 * The daemon checks this before using the buffers.
 */
#define VORTEX_SHM_MAGIC    0x56585348  /* "VXSH" in little-endian */
#define VORTEX_SHM_VERSION  2

/*
 * VortexSharedAudioState -- the layout of the shared memory region.
 *
 * This struct is mapped at the base of the shm region by both processes.
 * Field ordering is chosen to keep atomics naturally aligned.
 *
 * IMPORTANT: This struct must have a stable binary layout. Do not add
 * padding-sensitive types or reorder fields without bumping VORTEX_SHM_VERSION.
 */
typedef struct {
    /* ---- Header (verified by daemon on attach) ---- */
    _Atomic uint32_t    magic;      /* VORTEX_SHM_MAGIC */
    _Atomic uint32_t    version;    /* VORTEX_SHM_VERSION */

    /* ---- Shared configuration (plugin writes, daemon reads) ---- */
    _Atomic uint32_t    sampleRate;     /* e.g. 48000 */
    _Atomic uint32_t    channels;       /* e.g. 2 */
    _Atomic uint32_t    isActive;       /* 1 when IO is running, 0 when stopped */
    _Atomic uint32_t    generation;     /* incremented on each shm re-creation */

    /* ---- Output ring: plugin WRITES, daemon READS ---- */
    /* Positions are in samples (frames * channels). */
    _Atomic uint64_t    outputWritePos;
    _Atomic uint64_t    outputReadPos;

    /* ---- Input ring: daemon WRITES, plugin READS ---- */
    _Atomic uint64_t    inputWritePos;
    _Atomic uint64_t    inputReadPos;

    /* ---- Ring buffer storage (inline) ---- */
    /* Output buffer: VORTEX_RING_SAMPLES floats (stereo interleaved). */
    float               outputBuffer[VORTEX_RING_SAMPLES];

    /* Input buffer: VORTEX_RING_SAMPLES floats (stereo interleaved). */
    float               inputBuffer[VORTEX_RING_SAMPLES];
} VortexSharedAudioState;

/*
 * Total size of the shm region. Used for ftruncate and mmap.
 */
#define VORTEX_SHM_SIZE     ((size_t)sizeof(VortexSharedAudioState))

/* ---- Inline ring buffer helpers (usable from both C and Swift via bridging) ---- */

/*
 * Available samples for reading from a ring.
 * w = writePos (producer's cursor), r = readPos (consumer's cursor).
 */
static inline uint32_t
VortexShm_AvailableRead(uint64_t writePos, uint64_t readPos)
{
    return (uint32_t)(writePos - readPos);
}

/*
 * Available space for writing into a ring.
 */
static inline uint32_t
VortexShm_AvailableWrite(uint64_t writePos, uint64_t readPos)
{
    return VORTEX_RING_SAMPLES - VortexShm_AvailableRead(writePos, readPos);
}

#ifdef __cplusplus
}
#endif

#endif /* VORTEX_SHARED_AUDIO_H */
