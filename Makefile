OS=$(shell uname -s)

ifeq ($(OS), Darwin)
SHLIB_EXT=dylib
else
SHLIB_EXT=so
endif

ifeq ($(DEBUG), true)
CXXOPTS=-ggdb -O0 -DSIMDJSON_DEVELOPMENT_CHECKS
else
CXXOPTS=-ggdb -O3 -DNDEBUG
endif

OPENRESTY_PREFIX=/usr/local/openresty

#LUA_VERSION := 5.1
PREFIX ?=          /usr/local
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

CXX=c++

build: libsimdjson_ffi.$(SHLIB_EXT)

install: build
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/simdjson/
	$(INSTALL) -m 664 lib/resty/simdjson/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/simdjson/
	$(INSTALL) -m 775 ./libsimdjson_ffi.$(SHLIB_EXT) $(DESTDIR)/$(LUA_LIB_DIR)/

libsimdjson_ffi.$(SHLIB_EXT): simdjson.o libsimdjson_ffi.o
	$(CXX) $(CXXOPTS) -shared -o libsimdjson_ffi.$(SHLIB_EXT) simdjson.o libsimdjson_ffi.o

simdjson.o: src/simdjson.cpp src/simdjson.h
	$(CXX) $(CXXOPTS) -o simdjson.o -c -fPIC src/simdjson.cpp

libsimdjson_ffi.o: src/simdjson_ffi.cpp src/simdjson_ffi.h
	$(CXX) $(CXXOPTS) -o libsimdjson_ffi.o  -c -fPIC src/simdjson_ffi.cpp

clean:
	rm -f *.o *.$(SHLIB_EXT)

test: build
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -r t/

valgrind: build
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -r t/ 2>&1 | tee /dev/stderr | grep -q "match-leak-kinds: definite" && exit 1 || exit 0
