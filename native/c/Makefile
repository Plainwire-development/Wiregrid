CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wpedantic -Werror
CPPFLAGS ?= -Iinclude
AR ?= ar

all: libwiregrid.a

build/wiregrid.o: src/wiregrid.c include/wiregrid.h
	@mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -c $< -o $@

libwiregrid.a: build/wiregrid.o
	$(AR) rcs $@ $^

clean:
	rm -rf build libwiregrid.a tests/client_test tests/protocol_test

tests/client_test: tests/client_test.c libwiregrid.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< libwiregrid.a -o $@

test: tests/client_test
	python3 tests/run_protocol_test.py
