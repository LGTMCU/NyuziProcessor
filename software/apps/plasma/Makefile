#
# Copyright 2011-2015 Jeff Bush
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

TOPDIR=../../../

include $(TOPDIR)/build/target.mk

LIBS=-lc -los
SRCS=plasma.cpp
CFLAGS+=-ffast-math -std=c++11

OBJS := $(TOPDIR)/software/libs/libc/crt0.o $(SRCS_TO_OBJS)
DEPS := $(SRCS_TO_DEPS)

$(OBJ_DIR)/plasma.hex: $(OBJS)
	$(LD) -o $(OBJ_DIR)/plasma.elf $(LDFLAGS) $(OBJS) $(LIBS) $(LDFLAGS)
	$(ELF2HEX) -o $(OBJ_DIR)/plasma.hex $(OBJ_DIR)/plasma.elf

run: $(OBJ_DIR)/plasma.hex
	$(EMULATOR) -f 640x480 $(OBJ_DIR)/plasma.hex

fpgarun: $(OBJ_DIR)/plasma.hex
	$(SERIAL_BOOT) $(SERIAL_PORT) $(OBJ_DIR)/plasma.hex

clean:
	rm -rf $(OBJ_DIR)

-include $(DEPS)

