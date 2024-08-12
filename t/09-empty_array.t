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


=== TEST 1: encode empty table as json object
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:encode({})
            assert(type(v) == "string")
            assert(v == "{}")

            local v = parser:encode({a = {}})
            assert(type(v) == "string")
            assert(v == [[{"a":{}}]])

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



=== TEST 2: cjson empty_array userdata
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local v = parser:encode({arr = cjson.empty_array})
            assert(type(v) == "string")
            assert(v == [[{"arr":[]}]])

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



=== TEST 3: cjson empty_array_mt
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local empty_arr = setmetatable({}, cjson.empty_array_mt)
            local v = parser:encode({arr = empty_arr})
            assert(type(v) == "string")
            assert(v == [[{"arr":[]}]])

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



