OPENRESTY_PREFIX=/usr/local/openresty

#LUA_VERSION := 5.1
PREFIX ?=          /usr/local
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

#CXXOPTS=-ggdb -O0 -DSIMDJSON_DEVELOPMENT_CHECKS
CXX=c++
CXXOPTS=-ggdb -O3 -DNDEBUG

build: libsimdjson_ffi.so

install: build
	$(INSTALL) -m 664 lib/resty/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/
	$(INSTALL) -m 775 ./libsimdjson_ffi.so $(DESTDIR)$(LUA_LIB_DIR)/

libsimdjson_ffi.so: simdjson.o libsimdjson_ffi.o
	$(CXX) $(CXXOPTS) -shared -o libsimdjson_ffi.so simdjson.o libsimdjson_ffi.o

simdjson.o: simdjson.cpp simdjson.h
	$(CXX) $(CXXOPTS) -o simdjson.o -c -fPIC simdjson.cpp

libsimdjson_ffi.o: simdjson_ffi.cpp simdjson_ffi.h
	$(CXX) $(CXXOPTS) -o libsimdjson_ffi.o  -c -fPIC simdjson_ffi.cpp

clean:
	rm -f *.o *.so

test: build
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -r t/
