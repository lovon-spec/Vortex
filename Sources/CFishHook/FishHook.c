// FishHook.c — Minimal implementation of Facebook's fishhook algorithm.
// CFishHook
//
// This is a clean-room reimplementation of the fishhook technique for rebinding
// dynamically linked symbols at runtime on macOS/arm64. It works by:
//
//   1. Iterating all loaded Mach-O images via dyld APIs.
//   2. For each image, walking its load commands to find __DATA/__DATA_CONST
//      segments containing __la_symbol_ptr (lazy) and __nl_symbol_ptr (non-lazy)
//      sections.
//   3. Using the indirect symbol table to map each pointer slot back to its
//      symbol name.
//   4. When a symbol name matches a rebinding request, replacing the pointer
//      with the replacement function and (optionally) saving the original.
//
// This implementation targets macOS 14+ on arm64 exclusively.

#include "include/FishHook.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// On arm64 macOS, we always use 64-bit Mach-O structures.
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;

#define LC_SEGMENT_ARCH LC_SEGMENT_64

// ---------------------------------------------------------------------------
// Internal: linked list of pending rebindings
// ---------------------------------------------------------------------------

struct rebindings_entry {
    struct rebinding *rebindings;
    size_t count;
    struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head = NULL;
static int _dyld_callback_registered = 0;

// Forward declarations
static void _rebind_symbols_for_image(const mach_header_t *header, intptr_t slide);
static void _perform_rebindings_for_section(struct rebindings_entry *rebindings,
                                            section_t *section,
                                            intptr_t slide,
                                            nlist_t *symtab,
                                            const char *strtab,
                                            uint32_t *indirect_symtab);

// ---------------------------------------------------------------------------
// dyld image-added callback
// ---------------------------------------------------------------------------

static void _dyld_image_added_callback(const struct mach_header *header,
                                       intptr_t slide) {
    _rebind_symbols_for_image((const mach_header_t *)header, slide);
}

// ---------------------------------------------------------------------------
// Prepend a new set of rebindings to the global linked list.
// ---------------------------------------------------------------------------

static int _prepend_rebindings(struct rebinding rebindings[], size_t count) {
    struct rebindings_entry *new_entry =
        (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
    if (!new_entry) {
        return -1;
    }

    new_entry->rebindings = (struct rebinding *)malloc(
        sizeof(struct rebinding) * count);
    if (!new_entry->rebindings) {
        free(new_entry);
        return -1;
    }

    memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * count);
    new_entry->count = count;
    new_entry->next = _rebindings_head;
    _rebindings_head = new_entry;

    return 0;
}

// ---------------------------------------------------------------------------
// Public API: rebind_symbols
// ---------------------------------------------------------------------------

int rebind_symbols(struct rebinding rebindings[], size_t count) {
    if (_prepend_rebindings(rebindings, count) != 0) {
        return -1;
    }

    // Register the dyld callback on first call so future dlopen'd images
    // are also patched.
    if (!_dyld_callback_registered) {
        _dyld_callback_registered = 1;
        _dyld_register_func_for_add_image(_dyld_image_added_callback);
    } else {
        // Already registered; manually iterate existing images.
        uint32_t image_count = _dyld_image_count();
        for (uint32_t i = 0; i < image_count; i++) {
            const mach_header_t *header =
                (const mach_header_t *)_dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            _rebind_symbols_for_image(header, slide);
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Public API: rebind_symbols_image
// ---------------------------------------------------------------------------

int rebind_symbols_image(const void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t count) {
    // Temporarily push the rebindings, process the single image, then pop.
    struct rebindings_entry entry;
    entry.rebindings = rebindings;
    entry.count = count;
    entry.next = _rebindings_head;

    struct rebindings_entry *saved_head = _rebindings_head;
    _rebindings_head = &entry;

    _rebind_symbols_for_image((const mach_header_t *)header, slide);

    _rebindings_head = saved_head;
    return 0;
}

// ---------------------------------------------------------------------------
// Internal: process a single Mach-O image
// ---------------------------------------------------------------------------

static void _rebind_symbols_for_image(const mach_header_t *header,
                                      intptr_t slide) {
    if (!_rebindings_head) {
        return;
    }

    // Walk load commands to find:
    //   - LC_SEGMENT_64 for __LINKEDIT (contains symtab + indirect symtab data)
    //   - LC_SYMTAB (symbol table metadata)
    //   - LC_DYSYMTAB (dynamic symbol table metadata, has indirect symbols)
    //   - LC_SEGMENT_64 for __DATA and __DATA_CONST (contain symbol pointers)
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    // First pass: find linkedit, symtab, and dysymtab.
    const uint8_t *cursor = (const uint8_t *)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cursor;

        if (lc->cmd == LC_SEGMENT_ARCH) {
            segment_command_t *seg = (segment_command_t *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = seg;
            }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)lc;
        }

        cursor += lc->cmdsize;
    }

    if (!linkedit_segment || !symtab_cmd || !dysymtab_cmd) {
        return;
    }

    // Compute base addresses within __LINKEDIT.
    uintptr_t linkedit_base =
        (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab =
        (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    // Second pass: find __DATA and __DATA_CONST segments and their
    // __la_symbol_ptr / __nl_symbol_ptr / __got sections.
    cursor = (const uint8_t *)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cursor;

        if (lc->cmd == LC_SEGMENT_ARCH) {
            segment_command_t *seg = (segment_command_t *)lc;

            if (strcmp(seg->segname, SEG_DATA) == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0) {

                section_t *sections =
                    (section_t *)((const uint8_t *)seg + sizeof(segment_command_t));

                for (uint32_t j = 0; j < seg->nsects; j++) {
                    section_t *sect = &sections[j];
                    uint32_t type = sect->flags & SECTION_TYPE;

                    if (type == S_LAZY_SYMBOL_POINTERS ||
                        type == S_NON_LAZY_SYMBOL_POINTERS) {
                        _perform_rebindings_for_section(
                            _rebindings_head, sect, slide,
                            symtab, strtab, indirect_symtab);
                    }
                }
            }
        }

        cursor += lc->cmdsize;
    }
}

// ---------------------------------------------------------------------------
// Internal: rebind matching symbols within a single section
// ---------------------------------------------------------------------------

static void _perform_rebindings_for_section(
    struct rebindings_entry *rebindings,
    section_t *section,
    intptr_t slide,
    nlist_t *symtab,
    const char *strtab,
    uint32_t *indirect_symtab) {

    // Each entry in this section is a pointer-sized slot. The indirect symbol
    // table (indexed by section->reserved1) maps each slot to an index into
    // the main symbol table.
    uint32_t *indirect_symbol_indices =
        indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings =
        (void **)((uintptr_t)slide + section->addr);
    uint32_t num_slots =
        (uint32_t)(section->size / sizeof(void *));

    for (uint32_t i = 0; i < num_slots; i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];

        // Skip special indirect symbol table entries.
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        // Look up the symbol name from the string table.
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        const char *symbol_name = strtab + strtab_offset;

        // Symbol names in the string table have a leading underscore on
        // macOS (C name mangling). We compare against both the mangled name
        // and the name after stripping the leading '_'.
        int symbol_name_longer_than_1 =
            symbol_name[0] != '\0' && symbol_name[1] != '\0';

        // Walk the rebindings linked list looking for a match.
        struct rebindings_entry *entry = rebindings;
        while (entry) {
            for (size_t j = 0; j < entry->count; j++) {
                const char *target_name = entry->rebindings[j].name;

                // Compare against the demangled name (skip leading '_').
                if (symbol_name_longer_than_1 &&
                    strcmp(&symbol_name[1], target_name) == 0) {

                    // Save the original pointer if requested and if this is
                    // the first time we are rebinding this particular slot
                    // (avoid overwriting the saved original on repeated calls).
                    if (entry->rebindings[j].replaced != NULL &&
                        indirect_symbol_bindings[i] !=
                            entry->rebindings[j].replacement) {
                        *(entry->rebindings[j].replaced) =
                            indirect_symbol_bindings[i];
                    }

                    // Patch the symbol pointer.
                    indirect_symbol_bindings[i] =
                        entry->rebindings[j].replacement;

                    goto next_slot;
                }
            }
            entry = entry->next;
        }

    next_slot:;
    }
}
