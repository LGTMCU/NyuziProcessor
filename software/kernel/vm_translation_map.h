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

#pragma once

#include "memory_map.h"
#include "spinlock.h"

#define PA_TO_VA(x) ((unsigned int) (x) + PHYS_MEM_ALIAS)

#define PAGE_PRESENT 1
#define PAGE_WRITABLE 2
#define PAGE_EXECUTABLE 4
#define PAGE_SUPERVISOR 8
#define PAGE_GLOBAL 16

struct vm_translation_map
{
    spinlock_t lock;
    struct vm_translation_map *next;
    struct vm_translation_map **prev;
    unsigned int page_dir;
    unsigned int asid;
};

void vm_translation_map_init(void);
struct vm_translation_map *new_translation_map(void);
void destroy_translation_map(struct vm_translation_map*);
void vm_map_page(struct vm_translation_map *map, unsigned int va, unsigned int pa);
