/*
 * shm_bridge.h -- C bridge for shm_open/shm_unlink.
 *
 * On macOS, shm_open is declared as a variadic function in <sys/mman.h>,
 * which Swift cannot call directly. This header provides non-variadic
 * inline wrappers that Swift can import via -import-objc-header.
 *
 * Copyright 2024-2026 Vortex Authors. All rights reserved.
 * SPDX-License-Identifier: MIT
 */

#ifndef SHM_BRIDGE_H
#define SHM_BRIDGE_H

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

/*
 * Non-variadic wrapper around shm_open with an explicit mode_t parameter.
 * Swift can call this directly.
 */
static inline int vortex_shm_open(const char *name, int oflag, mode_t mode) {
    return shm_open(name, oflag, mode);
}

/*
 * Wrapper around shm_unlink.
 */
static inline int vortex_shm_unlink(const char *name) {
    return shm_unlink(name);
}

#endif /* SHM_BRIDGE_H */
