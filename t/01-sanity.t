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

=== TEST 1: json encode and decode
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj = parser:decode([[ { "hello": "world" } ]])

            assert(obj)
            assert(type(obj) == "table")
            assert(obj.hello == "world")

            local str = parser:encode(obj)

            assert(str)
            assert(type(str) == "string")

            ngx.say(str)
        }
    }
--- request
GET /t
--- response_body
{"hello":"world"}
--- no_error_log
[error]
[warn]
[crit]



