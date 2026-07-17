CC ?= cc
CFLAGS ?= -O3
REQUIRED_CFLAGS := -fPIC -Wall -Wextra -fopenmp
BUILD_DIR ?= build
TARGET ?= $(BUILD_DIR)/librackllm_pcre2.so

.PHONY: all clean
all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): rackllm_pcre2.c rackllm_pcre2.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(REQUIRED_CFLAGS) -MMD -MP \
	  -MF $(BUILD_DIR)/rackllm_pcre2.d -shared -o $@ $< -lpcre2-8

-include $(BUILD_DIR)/rackllm_pcre2.d

clean:
	rm -rf $(BUILD_DIR)
