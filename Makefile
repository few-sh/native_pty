# Makefile for libpty_bridge shared library

CC = gcc
CFLAGS = -Wall -Wextra -O2 -fPIC -pthread
LDFLAGS = -shared -pthread -lutil

# Detect OS
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Linux)
    TARGET = libpty_bridge.so
    INSTALL_DIR = lib/linux
endif
ifeq ($(UNAME_S),Darwin)
    TARGET = libpty_bridge.dylib
    INSTALL_DIR = lib/macos
    LDFLAGS = -dynamiclib -pthread -lutil
endif

SRC = src/pty_bridge.c
OBJ = $(SRC:.c=.o)

all: $(INSTALL_DIR)/$(TARGET)

$(INSTALL_DIR)/$(TARGET): $(OBJ)
	@mkdir -p $(INSTALL_DIR)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c src/pty_bridge.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJ)
	rm -rf lib/linux lib/macos lib/windows

.PHONY: all clean
