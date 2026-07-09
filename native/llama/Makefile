CC ?= cc
BUILD_DIR ?= build
TARGET ?= $(BUILD_DIR)/librackllm_llama.so
LLAMA_CLI ?= $(shell command -v llama-cli 2>/dev/null)
LLAMA_CPP_AUTO_PREFIX ?= $(if $(LLAMA_CLI),$(shell dirname "$$(dirname "$$(readlink -f "$(LLAMA_CLI)")")"),)
LLAMA_CPP_PREFIX ?= $(LLAMA_CPP_AUTO_PREFIX)
LLAMA_CPP_INCLUDE_DIR ?= $(if $(LLAMA_CPP_PREFIX),$(LLAMA_CPP_PREFIX)/include,)
LLAMA_CPP_LIB_DIR ?= $(if $(LLAMA_CPP_PREFIX),$(LLAMA_CPP_PREFIX)/lib,)
LLAMA_CPP_CFLAGS ?=
LLAMA_CPP_LIBS ?=

CFLAGS ?= -O3 -fPIC -Wall -Wextra

ifneq ($(LLAMA_CPP_INCLUDE_DIR),)
PREFIX_CFLAGS := -I$(LLAMA_CPP_INCLUDE_DIR)
endif
ifneq ($(LLAMA_CPP_LIB_DIR),)
PREFIX_LIBS := -L$(LLAMA_CPP_LIB_DIR) -Wl,-rpath,$(LLAMA_CPP_LIB_DIR)
endif
LLAMA_LIB := $(if $(wildcard $(LLAMA_CPP_LIB_DIR)/libllama.so),$(LLAMA_CPP_LIB_DIR)/libllama.so,-llama)

.PHONY: all clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): rackllm_llama.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(PREFIX_CFLAGS) $(LLAMA_CPP_CFLAGS) -shared -o $@ $< \
	  $(PREFIX_LIBS) $(LLAMA_CPP_LIBS) $(LLAMA_LIB)

clean:
	rm -rf $(BUILD_DIR)
