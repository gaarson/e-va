CC = gcc
CFLAGS = -O3 -Wall -Wextra -fPIC -I/usr/include/lua5.1
LDFLAGS = -shared

all: patcher_core.so

patcher_core.so: patcher_core.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f patcher_core.so
