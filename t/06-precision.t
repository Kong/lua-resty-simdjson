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


=== TEST 1: default precision is 16
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local str = parser:encode(1234567890123456)
            assert(str)
            assert(type(str) == "string")

            ngx.say(str)

            local str = parser:encode(1234567890.123456)
            assert(str)
            assert(type(str) == "string")

            ngx.say(str)
        }
    }
--- request
GET /t
--- response_body
1234567890123456
1234567890.123456
--- no_error_log
[error]
[warn]
[crit]


=== TEST 2: set precision is ok
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            parser:encode_number_precision(14)

            local str = parser:encode(1234567890123456)
            assert(str)
            assert(type(str) == "string")

            ngx.say(str)

            parser:encode_number_precision(3)

            local str = parser:encode(123.4)
            assert(str)
            assert(type(str) == "string")

            ngx.say(str)
        }
    }
--- request
GET /t
--- response_body
1.2345678901235e+15
123
--- no_error_log
[error]
[warn]
[crit]



