// FishHook.h — Minimal implementation of Facebook's fishhook algorithm.
// CFishHook
//
// Provides runtime rebinding of dynamically linked C functions by patching
// the Mach-O lazy and non-lazy symbol pointer tables. This allows interposing
// arbitrary CoreAudio (or any dylib) functions at runtime.
//
// Reference: https://github.com/facebook/fishhook
// License: BSD-style (original Facebook fishhook is BSD-licensed)

#ifndef FISHHOOK_H
#define FISHHOOK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Describes a single symbol rebinding request.
///
/// - `name`:        The symbol name to rebind (e.g., "AudioComponentInstanceNew").
/// - `replacement`: Pointer to the replacement function.
/// - `replaced`:    On success, the original function pointer is written here.
///                  May be NULL if the caller does not need the original.
struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

/// Rebind symbols in all currently loaded Mach-O images.
///
/// Walks every loaded image's `__DATA` (and `__DATA_CONST`) segments, finds
/// lazy and non-lazy symbol pointer sections, and replaces entries matching
/// any of the given symbol names with the provided replacement pointers.
///
/// - Parameters:
///   - rebindings: Array of rebinding descriptors.
///   - count:      Number of elements in `rebindings`.
/// - Returns: 0 on success, -1 on failure.
int rebind_symbols(struct rebinding rebindings[], size_t count);

/// Rebind symbols only within a specific Mach-O image.
///
/// Same as `rebind_symbols` but operates on a single image identified by
/// its header and ASLR slide.
///
/// - Parameters:
///   - header:     The mach_header_64 of the target image.
///   - slide:      The ASLR slide for the image.
///   - rebindings: Array of rebinding descriptors.
///   - count:      Number of elements in `rebindings`.
/// - Returns: 0 on success, -1 on failure.
int rebind_symbols_image(const void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t count);

#ifdef __cplusplus
}
#endif

#endif /* FISHHOOK_H */
