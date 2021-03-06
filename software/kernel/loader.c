//
// Copyright 2016 Jeff Bush
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#include "elf.h"
#include "fs.h"
#include "libc.h"
#include "loader.h"
#include "thread.h"
#include "vm_page.h"
#include "vm_translation_map.h"

#define MAX_SEGMENTS 4

// Load program into memory. Because this accesses virtual addresses,
// the thread that executes this must be running the address space of
// the new process.
int load_program(const char *filename,
                 unsigned int *out_entry)
{
    struct Elf32_Ehdr image_header;
    struct Elf32_Phdr segments[MAX_SEGMENTS];
    struct vm_translation_map *map = current_thread()->map;

    struct file_handle *file = open_file(filename);
    if (file == 0)
    {
        kprintf("Couldn't find kernel file\n");
        return -1;
    }

    if (read_file(file, 0, &image_header, sizeof(image_header)) < 0)
    {
        kprintf("Couldn't read header\n");
        return -1;
    }

    if (memcmp(image_header.e_ident, ELF_MAGIC, 4) != 0)
    {
        kprintf("Not an elf file\n");
        return -1;
    }

    if (image_header.e_machine != EM_NYUZI)
    {
        kprintf("Incorrect architecture\n");
        return -1;
    }

    if (read_file(file, image_header.e_phoff, &segments, image_header.e_phnum
                  * sizeof(struct Elf32_Phdr)) < 0)
    {
        kprintf("error reading segment table\n");
        return -1;
    }

    for (int segment_index = 0; segment_index < image_header.e_phnum; segment_index++)
    {
        const struct Elf32_Phdr *segment = &segments[segment_index];
        int num_pages;
        int page_index;
        unsigned int pte_flags;

        if ((segment->p_type & PT_LOAD) == 0)
            continue;	// Skip non-loadable segment

        // Ignore empty segments (which are sometimes emitted by the linker)
        if (segment->p_memsz == 0)
            continue;

        kprintf("Loading segment %d offset %08x vaddr %08x file size %08x mem size %08x flags %x\n",
               segment_index, segment->p_offset, segment->p_vaddr, segment->p_filesz,
               segment->p_memsz, segment->p_flags);

        // Ensure this doesn't clobber the kernel
        if (segment->p_vaddr > 0xc0000000 || (segment->p_vaddr + segment->p_memsz) > 0xc0000000
            || (segment->p_vaddr + segment->p_memsz) < segment->p_vaddr)
        {
            kprintf("segment %08x-%08x clobbers kernel, aborting\n", segment->p_vaddr,
                segment->p_vaddr + segment->p_memsz);
            return -1;
        }

        pte_flags = PAGE_PRESENT;
#if 0
        if (segment->p_flags & PF_W)
            pte_flags |= PAGE_WRITABLE;
#else
        // XXX needs to be writable to read data into it. fixme.
        pte_flags |= PAGE_WRITABLE;
#endif

        if (segment->p_flags & PF_X)
            pte_flags |= PAGE_EXECUTABLE;

        // Map region
        num_pages = (segment->p_memsz + PAGE_SIZE - 1) / PAGE_SIZE;
        for (page_index = 0; page_index < num_pages; page_index++)
        {
            vm_map_page(map, segment->p_vaddr + page_index * PAGE_SIZE,
                        vm_allocate_page() | pte_flags);
        }

        // Load initialized portion
        if (read_file(file, segment->p_offset, (void*) segment->p_vaddr,
                     segment->p_filesz) < 0)
        {
            kprintf("Error loading initialized portion\n");
            return -1;
        }

        // Zero uninitialized portion of segment (BSS)
        memset((char*) segment->p_vaddr + segment->p_filesz, 0,
               segment->p_memsz - segment->p_filesz);
    }

    *out_entry = image_header.e_entry;
    return 0;
}

