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

=== TEST 1: ngx.null should be same as cjson.null
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj = parser:decode([[ { "v": null } ]])

            assert(obj)
            assert(type(obj) == "table")
            assert(obj.v == ngx.null)
            assert(obj.v == cjson.null)

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



