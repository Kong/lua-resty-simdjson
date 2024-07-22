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

            local v = parser:encode(100)
            assert(type(v) == "string")
            assert(v == "100")

            local v = parser:encode(-10)
            assert(type(v) == "string")
            assert(v == "-10")

            local v = parser:encode(3.14)
            assert(type(v) == "string")
            assert(v == "3.14")

            local v = parser:encode(1e2)
            assert(type(v) == "string")
            assert(v == "100")

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

            local v = parser:encode(true)
            assert(type(v) == "string")
            assert(v == "true")

            local v = parser:encode(false)
            assert(type(v) == "string")
            assert(v == "false")

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

            local v = parser:encode(ngx.null)
            assert(type(v) == "string")
            assert(v == "null")

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

            local v = parser:encode([[demo json]])
            assert(type(v) == "string")
            assert(v == [["demo json"]])

            local v = parser:encode([[demo '" json]])
            assert(type(v) == "string")
            assert(v == [["demo '\" json"]])

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

            local v = parser:encode({1, 2, 3})
            assert(type(v) == "string")
            assert(v == "[1,2,3]")

            local v = parser:encode({true, 2, "abc"})
            assert(type(v) == "string")
            assert(v == "[true,2,\"abc\"]")

            local v = parser:encode({1, ngx.null, 3})
            assert(type(v) == "string")
            assert(v == "[1,null,3]")

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

            local v = parser:encode({a = 1, b = true, c = "string"})
            assert(type(v) == "string")
            assert(v:find([["a":1]], 1, true))
            assert(v:find([["b":true]], 1, true))
            assert(v:find([["c":"string"]], 1, true))

            local v = parser:encode({a = 1.1, b = ngx.null, c = false})
            assert(type(v) == "string")
            assert(v:find([["a":1.1]], 1, true))
            assert(v:find([["b":null]], 1, true))
            assert(v:find([["c":false]], 1, true))

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

            local v = parser:encode({
              a = {1, 2.0, 3.14},
              b = {x = "xx", y = true},
              c = {{1, 2}, {k = "v"}},
            })

            assert(type(v) == "string")
            assert(v:find([==["a":[1,2,3.14]]==], 1, true))
            assert(v:find([==["c":[[1,2],{"k":"v"}]]==], 1, true))
            assert(v:find([==["x":"xx"]==], 1, true))
            assert(v:find([==["y":true]==], 1, true))

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



=== TEST 8: nested array data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:encode({{{{{{{{{{1}}}}}}}}}})
            assert(type(v) == "string")

            ngx.say(v)
        }
    }
--- request
GET /t
--- response_body
[[[[[[[[[[1]]]]]]]]]]
--- no_error_log
[error]
[warn]
[crit]



