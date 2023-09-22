# lua-resty-simdjson

The fastest way to decode JSON in OpenResty for latency sensitive applications.

# Table of Contents

* [lua-resty-simdjson](#lua-resty-simdjson)
* [Synopsis](#synopsis)
* [APIs](#apis)
    * [simdjson.new](#simdjsonnew)
    * [simdjson.destroy](#simdjsondestroy)
    * [simdjson.decode](#simdjsondecode)
* [Performance characteristics](#performance-characteristics)
    * [Speed & Latency](#speed--latency)
    * [Memory](#memory)
* [License](#license)

# Synopsis

```lua
local simdjson = require("resty.simdjson")

local parser = simdjson.new()
-- local parser = simdjson.new(true) -- yieldable parser

local tbl = parser:decode([[ { "hello": "world" } ]])
-- parser:destroy() -- optional: destroy parser explicitly

-- do_something(tbl)
```

# APIs

## simdjson.new

**syntax:** *parser = simdjson.new(yield?)*

**context:** *any context *

Create a new parser instance. The parser instance is a data structure that holds
all required data structure and state information for parsing a JSON string.

If `yield` is `true`, then the parser will yield periodically during JSON parsing to reduce
latency impact to the Nginx event loop. Default is *false*.

**Safety:** JSON parser instance does not share any global state, however, they are **not**
reentrant meaning if `yield` is set to `true`, concurrent requests should **not** use the same
parser instance to parse JSON concurrently.

**Performance:** When decoding large number of JSON strings in a loop, **do not** create
a parser instance for each run to avoid frequent memory allocations. Reuse the same parser
instance and call the `:decode` method repeatedly. You should only `:destroy` the instance
if it is not needed for a while and you would like the memory used by the parser to be freed.

[Back to TOC](#table-of-contents)

## simdjson.destroy

**syntax:** *parser:destroy()*

**context:** *any context *

Destroys and deallocates any memory used by the JSON parser instance. This usually happens
automatically when the parser gets garbage collected by LuaJIT, however you can call this
method manually to free up memory immediately.

After calling this method, `parser` can not be used again.

[Back to TOC](#table-of-contents)

## simdjson.decode

**syntax:** *obj = parser:decode(json)*

**context:** *any context *

Use `parser` to parse a `json` string into Lua object. `object` could be a scalar type
in case JSON is a number, string, boolean, null, or Lua table in case the
JSON string is an array or object.

**Safety:** If the parser was initiated to be yieldable, then this method is **not** reentrant.
Do not call the `:decode` method on the same `parser` instance from different thread/request
concurrently.

[Back to TOC](#table-of-contents)

# Performance characteristics

## Speed & Latency
Compared to [lua-cjcon](https://github.com/openresty/lua-cjson), which is by far the most
commonly used JSON decoder in the OpenResty/LuaJIT ecosystem, lua-resty-simdjson significantly
improves the proxy path latency when dealing with large JSON inputs when yielding is enabled.

Due to the extremely high speed of simdjson, efficient data structure stream from C land
to Lua land and usage of LuaJIT FFI instead of Lua C API for table building,
the total decode time is also slightly faster than lua-cjson. During a benchmark
to decode [a 100MB JSON sample](https://github.com/seductiveapps/largeJSON/blob/master/100mb.json),
lua-cjson took more than 400ms while lua-resty-simdjson
finished decode in average 350ms (12% speedup) even with yielding enabled.

The maximum proxy path latency during decode was measured to be 4ms instead of 420ms using [wrk2](https://github.com/giltene/wrk2)
in constant throughput mode (99% reduction):

```shell
# With lua-resty-simdjson
$ ./wrk -c 10 -d 20 -t 4 -R 2000 http://127.0.0.1:8080
Initialised 4 threads in 0 ms.
Running 20s test @ http://127.0.0.1:8080
  4 threads and 10 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     0.99ms  381.63us   4.13ms   63.31%
    Req/Sec   530.22     66.66   666.00     59.59%
  40000 requests in 20.00s, 6.45MB read
Requests/sec:   1999.86
Transfer/sec:    330.05KB

# With lua-cjson
$ ./wrk -c 10 -d 20 -t 4 -R 2000 http://127.0.0.1:8080
Initialised 4 threads in 0 ms.
Running 20s test @ http://127.0.0.1:8080
  4 threads and 10 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     9.97ms   49.55ms 421.63ms   96.32%
    Req/Sec   500.34    132.27     1.00k    92.86%
  40000 requests in 20.00s, 6.45MB read
Requests/sec:   1999.86
Transfer/sec:    330.05KB
```

[Back to TOC](#table-of-contents)

## Memory
The lua-resty-simdjson library will use more memory than lua-cjson during parsing due to various internal
data structure simdjson allocates. The overhead is roughly equal to the size of the JSON string
and can be freed immediately after parse with the `:destroy` method.

[Back to TOC](#table-of-contents)

# License

Copyright 2023 Datong Sun (dndx@idndx.com)

Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
[https://www.apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)> or the MIT license
<LICENSE-MIT or [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)>, at your
option. Files in the project may not be
copied, modified, or distributed except according to those terms.

[Back to TOC](#table-of-contents)
