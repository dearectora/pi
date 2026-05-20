CC = clang
CFLAGS = -O2 -Wall -Wextra -std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700
LDFLAGS = -lcjson -lpthread
SRCS = $(wildcard src/*.c)
TARGET = wisp

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
