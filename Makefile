#CXXOPTS=-ggdb -O0 -DSIMDJSON_DEVELOPMENT_CHECKS
CXXOPTS=-ggdb -O3 -DNDEBUG

libs: libsimdjson_ffi.so

libsimdjson_ffi.so: simdjson.o libsimdjson_ffi.o
	c++ $(CXXOPTS) -shared -o libsimdjson_ffi.so simdjson.o libsimdjson_ffi.o

simdjson.o: simdjson.cpp simdjson.h
	c++ $(CXXOPTS) -o simdjson.o -c -fPIC simdjson.cpp

libsimdjson_ffi.o: simdjson_ffi.cpp simdjson_ffi.h
	c++ $(CXXOPTS) -o libsimdjson_ffi.o  -c -fPIC simdjson_ffi.cpp

clean:
	rm *.o *.so
