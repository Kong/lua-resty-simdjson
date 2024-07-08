OS=$(shell uname -s)

ifeq ($(OS), Darwin)
SHLIB_EXT=dylib
else
SHLIB_EXT=so
endif

OPENRESTY_PREFIX=/usr/local/openresty

#LUA_VERSION := 5.1
PREFIX ?=          /usr/local
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

#CXXOPTS=-ggdb -O0 -DSIMDJSON_DEVELOPMENT_CHECKS
CXX=c++
CXXOPTS=-ggdb -O3 -DNDEBUG

build: libsimdjson_ffi.$(SHLIB_EXT)

install: build
	$(INSTALL) -m 664 lib/resty/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/
	$(INSTALL) -m 775 ./libsimdjson_ffi.$(SHLIB_EXT) $(DESTDIR)$(LUA_LIB_DIR)/

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
