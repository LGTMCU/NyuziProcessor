//
// Copyright 2015-2016 Jeff Bush
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

#include "fs.h"
#include "kernel_heap.h"
#include "libc.h"
#include "sdmmc.h"
#include "vm_page.h"

#define RAMDISK_BASE ((unsigned char*) 0x4000000)
#define FS_MAGIC "spfs"

struct file_handle
{
    unsigned int base_location;
    unsigned int length;
};

struct directory_entry
{
    unsigned int start_offset;
    unsigned int length;
    char name[32];
};

struct fs_header
{
    char magic[4];
    unsigned int num_directory_entries;
    struct directory_entry dir[1];
};

static int initialized;
static int use_ramdisk;
static struct fs_header *directory;

int read_block(int block_num, void *ptr)
{
    if (use_ramdisk)
    {
        memcpy(ptr, RAMDISK_BASE + block_num * BLOCK_SIZE, BLOCK_SIZE);
        return BLOCK_SIZE;
    }
    else
        return read_sdmmc_device(block_num, ptr);
}

static int init_file_system(void)
{
    char super_block[BLOCK_SIZE];
    int num_directory_blocks;
    int block_num;
    struct fs_header *header;

    // SDMMC not supported on FPGA currently. Fall back to ramdisk if it fails.
    if (init_sdmmc_device() < 0)
    {
        printf("init_file_system: SDMMC init failed, using ramdisk\n");
        use_ramdisk = 1;
    }

    // Read directory
    if (read_block(0, super_block) <= 0)
    {
        printf("init_file_system: error reading directory\n");
        return -1;
    }

    header = (struct fs_header*) super_block;
    if (memcmp(header->magic, FS_MAGIC, 4) != 0)
    {
        printf("init_file_system: invalid magic value\n");
        return -1;
    }

    num_directory_blocks = ((header->num_directory_entries - 1)
                          * sizeof(struct directory_entry)
                          + sizeof(struct fs_header) + BLOCK_SIZE - 1)
                          / BLOCK_SIZE;
    directory = (struct fs_header*) kmalloc((num_directory_blocks * BLOCK_SIZE + PAGE_SIZE - 1)
        & ~(PAGE_SIZE - 1));
    memcpy(directory, super_block, BLOCK_SIZE);
    for (block_num = 1; block_num < num_directory_blocks; block_num++)
    {
        if (read_block(block_num, ((char*)directory) + BLOCK_SIZE * block_num) <= 0)
            return -1;
    }

    return 0;
}

struct file_handle *open_file(const char *path)
{
    int directory_index;
    struct file_handle *handle;

    if (!initialized)
    {
        if (init_file_system() < 0)
            return -1;

        initialized = 1;
    }

    for (directory_index = 0; directory_index < directory->num_directory_entries; directory_index++)
    {
        struct directory_entry *entry = directory->dir + directory_index;
        if (strcmp(entry->name, path) == 0)
        {
            handle = (struct file_handle*) malloc(sizeof(struct file_handle));
            handle->base_location = entry->start_offset;
            handle->length = entry->length;
            return entry;
        }
    }

    return 0;
}

int read_file(struct file_handle *handle, unsigned int offset, void *out_ptr, int size_to_copy)
{
    char tmp_block[BLOCK_SIZE];
    int slice_length;
    int total_read = 0;
    int offset_in_block;
    int block_number;
    int fs_offset = handle->base_location + offset;

    offset_in_block = fs_offset & (BLOCK_SIZE - 1);
    block_number = fs_offset / BLOCK_SIZE;
    while (total_read < size_to_copy)
    {
        if (offset_in_block == 0 && (size_to_copy - total_read) >= BLOCK_SIZE)
        {
            if (read_block(block_number, ((unsigned char*)out_ptr) + total_read) < 0)
            {
                printf("Error reading SDMMC device\n");
                return -1;
            }

            total_read += BLOCK_SIZE;
            block_number++;
        }
        else
        {
            if (read_block(block_number, tmp_block) < 0)
            {
                printf("Error reading SDMMC device\n");
                return -1;
            }

            slice_length = BLOCK_SIZE - offset_in_block;
            if (slice_length > size_to_copy - total_read)
                slice_length = size_to_copy - total_read;

            memcpy(((unsigned char*) out_ptr) + total_read, tmp_block + offset_in_block,
                   slice_length);
            total_read += slice_length;
            offset_in_block = 0;
            block_number++;
        }
    }

    return total_read;
}
