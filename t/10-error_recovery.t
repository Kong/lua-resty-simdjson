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


=== TEST 1: a failed decode does not change what the next decode returns
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local decoder = require("resty.simdjson.decoder")

            -- every input fails part way through a nested value, so the
            -- decoder gives up while it still holds iteration state
            local malformed = {
                '{"a":[1,2e]}',
                '{"a":{"b":1e}}',
                '{"a":[1,2.2.2]}',
                '{"a":"\\uZZZZ"}',
                '[[1,2e]]',
                '{"a":[1,2],}',
                '{"a":[1,[2,[3,4e]]]}',
            }

            local dec = decoder.new(false)

            for _, json in ipairs(malformed) do
                local res, err = dec:process(json)
                assert(res == nil, "expected " .. json .. " to fail")
                assert(err ~= nil)

                -- one failure used to break several later decodes, not only
                -- the next one, so check more than a single round
                for i = 1, 5 do
                    local ok, err = dec:process('{"a":[1,2],"b":{"c":3}}')
                    assert(err == nil, "decode " .. i .. " after " .. json
                                       .. ": " .. tostring(err))
                    assert(ok.a[1] == 1)
                    assert(ok.a[2] == 2)
                    assert(ok.b.c == 3)
                end
            end

            dec:destroy()

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



=== TEST 2: recovery works for documents larger than one operation batch
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local decoder = require("resty.simdjson.decoder")

            local t = {}
            for i = 1, 3000 do
                t[i] = i
            end
            local big = "[" .. table.concat(t, ",") .. "]"

            local dec = decoder.new(false)

            for _ = 1, 10 do
                local res, err = dec:process('{"a":[1,2e]}')
                assert(res == nil)
                assert(err ~= nil)

                local ok, err = dec:process(big)
                assert(err == nil, tostring(err))
                assert(#ok == 3000)
                assert(ok[1] == 1)
                assert(ok[3000] == 3000)
            end

            dec:destroy()

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



=== TEST 3: a failed decode reports the same error every time
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local decoder = require("resty.simdjson.decoder")

            local dec = decoder.new(false)
            local first

            for i = 1, 5 do
                local res, err = dec:process('{"a":[1,2e]}')
                assert(res == nil)
                assert(err:find("NUMBER_ERROR", 1, true), err)

                first = first or err
                assert(err == first, "error " .. i .. " changed: " .. err)
            end

            dec:destroy()

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
