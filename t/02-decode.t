# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * blocks() * 5;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "$pwd/?.so;;";
};

no_long_string();
no_diff();

run_tests();

__DATA__


=== TEST 1: number data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode("100")
            assert(type(v) == "number")
            assert(v == 100)

            local v = parser:decode("-10")
            assert(type(v) == "number")
            assert(v == -10)

            local v = parser:decode("3.14")
            assert(type(v) == "number")
            assert(v == 3.14)

            local v = parser:decode("1e2")
            assert(type(v) == "number")
            assert(v == 100)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 2: boolean data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode("true")
            assert(type(v) == "boolean")
            assert(v == true)

            local v = parser:decode("false")
            assert(type(v) == "boolean")
            assert(v == false)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 3: null data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode("null")
            assert(type(v) == "userdata")
            assert(v == ngx.null)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 4: string data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode([["demo json"]])
            assert(type(v) == "string")
            assert(v == "demo json")

            local v = parser:decode([["demo '\" json"]])
            assert(type(v) == "string")
            assert(v == [[demo '" json]])

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 5: array data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode("[1, 2, 3]")
            assert(type(v) == "table")
            assert(#v == 3)
            assert(v[1] == 1 and v[2] == 2 and v[3] == 3)

            local v = parser:decode("[true, 2, \"abc\"]")
            assert(type(v) == "table")
            assert(#v == 3)
            assert(v[1] == true and v[2] == 2 and v[3] == "abc")

            local v = parser:decode("[1, null, 3]")
            assert(type(v) == "table")
            assert(#v == 3)
            assert(v[1] == 1 and v[2] == ngx.null and v[3] == 3)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 6: object data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode([[{"a":1, "b":true, "c":"string"}]])
            assert(type(v) == "table")
            assert(v.a == 1 and v.b == true and v.c == "string")

            local v = parser:decode([[{"a":1.0, "b":null, "c":false}]])
            assert(type(v) == "table")
            assert(v.a == 1.0 and v.b == ngx.null and v.c == false)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 7: complex data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode([[{
              "a":[1, 2.0, 3.14],
              "b":{"x":"xx", "y":true},
              "c":[[1, 2], {"k":"v"}]
            }]])

            assert(type(v) == "table")
            assert(type(v.a) == "table" and #v.a == 3)
            assert(type(v.b) == "table")
            assert(type(v.c) == "table")

            assert(#v.a == 3 and v.a[3] == 3.14)
            assert(v.b.x == "xx" and v.b.y == true)
            assert(#v.c[1] == 2 and v.c[2].k == "v")

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]



=== TEST 7: invalid data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:decode([[{ "a":1, }]])
            assert(v == nil)

            local v = parser:decode([[{ "a":[1, 2.0 }]])
            assert(v == nil)

            local v = parser:decode([[{ "a":.9 }]])
            assert(v == nil)

            local v = parser:decode([[{ "a":0x10 }]])
            assert(v == nil)

            local v = parser:decode([[{ "a":'???' }]])
            assert(v == nil)

            local v = parser:decode([[{ "a":True }]])
            assert(v == nil)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]


