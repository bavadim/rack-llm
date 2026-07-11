CC ?= cc
CFLAGS ?= -O3 -fPIC -Wall -Wextra
BUILD_DIR ?= build
TARGET ?= $(BUILD_DIR)/librackllm_pcre2.so

.PHONY: all clean
all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): rackllm_pcre2.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@ $< -lpcre2-8

clean:
	rm -rf $(BUILD_DIR)
