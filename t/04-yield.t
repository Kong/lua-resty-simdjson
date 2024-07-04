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

=== TEST 1: encode should yield
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local _sleep = _G.ngx.sleep
            _G.ngx.sleep = function()
                ngx.say("yield")
            end

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new(true)
            assert(parser)

            local str = parser:encode({ str = string.rep("a", 2100) })

            assert(str)
            assert(type(str) == "string")

            _G.ngx.sleep = _sleep
        }
    }
--- request
GET /t
--- response_body
yield
--- no_error_log
[error]
[warn]
[crit]



=== TEST 2: decode should yield
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local _sleep = _G.ngx.sleep
            _G.ngx.sleep = function()
                ngx.say("yield")
            end

            local a = {}
            for i = 1, 1000 do
                a[i] = i
            end

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new(true)
            assert(parser)

            local obj = parser:decode("[" .. table.concat(a, ",") .. "]")
            assert(obj)
            assert(type(obj) == "table")

            _G.ngx.sleep = _sleep
        }
    }
--- request
GET /t
--- response_body
yield
--- no_error_log
[error]
[warn]
[crit]



