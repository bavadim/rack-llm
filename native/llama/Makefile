CC ?= cc
BUILD_DIR ?= build
TARGET ?= $(BUILD_DIR)/librackllm_llama.so
CONFORMANCE_LIB ?= $(BUILD_DIR)/librackllm_llama_conformance.so
CONFORMANCE_TARGET ?= $(BUILD_DIR)/fixed-cohort-replay
LLAMA_CLI ?= $(shell command -v llama-cli 2>/dev/null)
LLAMA_CPP_AUTO_PREFIX ?= $(if $(LLAMA_CLI),$(shell dirname "$$(dirname "$$(readlink -f "$(LLAMA_CLI)")")"),)
LLAMA_CPP_PREFIX ?= $(LLAMA_CPP_AUTO_PREFIX)
LLAMA_CPP_INCLUDE_DIR ?= $(if $(LLAMA_CPP_PREFIX),$(LLAMA_CPP_PREFIX)/include,)
LLAMA_CPP_LIB_DIR ?= $(if $(LLAMA_CPP_PREFIX),$(LLAMA_CPP_PREFIX)/lib,)
LLAMA_CPP_CFLAGS ?=
LLAMA_CPP_LIBS ?=

CFLAGS ?= -O3
REQUIRED_CFLAGS := -fPIC -Wall -Wextra -fopenmp

ifneq ($(LLAMA_CPP_INCLUDE_DIR),)
PREFIX_CFLAGS := -I$(LLAMA_CPP_INCLUDE_DIR)
endif
ifneq ($(LLAMA_CPP_LIB_DIR),)
PREFIX_LIBS := -L$(LLAMA_CPP_LIB_DIR) -Wl,-rpath,$(LLAMA_CPP_LIB_DIR)
endif
LLAMA_LIB := $(if $(wildcard $(LLAMA_CPP_LIB_DIR)/libllama.so),$(LLAMA_CPP_LIB_DIR)/libllama.so,-llama)

.PHONY: all conformance clean

all: $(TARGET)

conformance: $(CONFORMANCE_TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): rackllm_llama.c rackllm_llama.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(REQUIRED_CFLAGS) $(PREFIX_CFLAGS) $(LLAMA_CPP_CFLAGS) \
	  -MMD -MP -MF $(BUILD_DIR)/rackllm_llama.d -shared -o $@ $< \
	  $(PREFIX_LIBS) $(LLAMA_CPP_LIBS) $(LLAMA_LIB)

$(CONFORMANCE_LIB): rackllm_llama.c rackllm_llama.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(REQUIRED_CFLAGS) $(PREFIX_CFLAGS) $(LLAMA_CPP_CFLAGS) \
	  -DRACKLLM_ENABLE_CONFORMANCE -shared -o $@ $< \
	  $(PREFIX_LIBS) $(LLAMA_CPP_LIBS) $(LLAMA_LIB)

$(CONFORMANCE_TARGET): ../../tests/native/fixed-cohort-replay.c $(CONFORMANCE_LIB) | $(BUILD_DIR)
	$(CC) -O2 -Wall -Wextra -I. -o $@ $< -L$(BUILD_DIR) -lrackllm_llama_conformance \
	  -Wl,-rpath,$(abspath $(BUILD_DIR)) $(PREFIX_LIBS)

-include $(BUILD_DIR)/rackllm_llama.d

clean:
	rm -rf $(BUILD_DIR)
