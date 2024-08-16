# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * blocks() * 5;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?/init.lua;$pwd/lib/?.lua;;";
    lua_package_cpath "$pwd/?.so;;";
};

no_long_string();
no_diff();

run_tests();

__DATA__


=== TEST 1: array_mt on empty tables
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local data = {}
            setmetatable(data, cjson.array_mt)

            local v = parser:encode(data)
            assert(type(v) == "string")

            ngx.say(v)
        }
    }
--- request
GET /t
--- response_body
[]
--- no_error_log
[error]
[warn]
[crit]



=== TEST 2: array_mt on non-empty tables
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local data = { "foo", "bar" }
            setmetatable(data, cjson.array_mt)

            local v = parser:encode(data)
            assert(type(v) == "string")

            ngx.say(v)
        }
    }
--- request
GET /t
--- response_body
["foo","bar"]
--- no_error_log
[error]
[warn]
[crit]



=== TEST 3: array_mt on non-empty tables with holes
--- ONLY
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local data = {}
            data[1] = "foo"
            data[2] = "bar"
            data[4] = "last"
            data[9] = "none"
            setmetatable(data, cjson.array_mt)

            local v = parser:encode(data)
            assert(type(v) == "string")

            ngx.say(v)
        }
    }
--- request
GET /t
--- response_body
["foo","bar",null,"last"]
--- no_error_log
[error]
[warn]
[crit]



=== TEST 4: array_mt on tables with hash part
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local data = {}
            data.foo = "bar"
            data[1] = "hello"
            data[3] = "world"
            setmetatable(data, cjson.array_mt)

            local v = parser:encode(data)
            assert(type(v) == "string")

            ngx.say(v)
        }
    }
--- request
GET /t
--- response_body
["hello",null,"world"]
--- no_error_log
[error]
[warn]
[crit]



