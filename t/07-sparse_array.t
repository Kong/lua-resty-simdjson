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


=== TEST 1: encode array with holes
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local str = parser:encode({ [3] = 3 })

            assert(str)
            assert(type(str) == "string")

            ngx.say(str)
        }
    }
--- request
GET /t
--- response_body
[null,null,3]
--- no_error_log
[error]
[warn]
[crit]


=== TEST 2: encode array with negative index to object
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local str = parser:encode({ [-1] = -1, [3] = 3 })

            assert(str)
            assert(type(str) == "string")
            assert(str:find([["-1":-1]], 1, true))
            assert(str:find([["3":3]], 1, true))

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



