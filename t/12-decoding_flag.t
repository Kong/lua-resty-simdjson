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


=== TEST 1: a raised decode does not lock a yieldable decoder
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local decoder = require("resty.simdjson.decoder")

            local dec = decoder.new(true)

            -- The builders raise when the opcode stream is not what they
            -- expect. Force that, the way a corrupted parser state would.
            local build = dec._build
            dec._build = function()
                error("simulated build failure")
            end

            local ok, err = pcall(dec.process, dec, '{"a":1}')
            assert(not ok, "expected the build to raise")
            assert(string.find(err, "simulated build failure", 1, true),
                   "lost the original error: " .. tostring(err))

            dec._build = build

            -- the decoder has to stay usable
            local res, err2 = dec:process('{"a":[1,2],"b":{"c":3}}')
            assert(err2 == nil, "reuse failed: " .. tostring(err2))
            assert(res.a[1] == 1)
            assert(res.a[2] == 2)
            assert(res.b.c == 3)

            -- and destroyable
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



=== TEST 2: the reentrancy guard still rejects a concurrent decode
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

            local dec = decoder.new(true)

            local reentrant_err

            -- A yieldable decode yields between batches. Enter process()
            -- again from another light thread while the first one waits.
            local co = ngx.thread.spawn(function()
                local res, err = dec:process(big)
                assert(err == nil, "outer decode failed: " .. tostring(err))
                assert(#res == 3000)
            end)

            local ok, err = pcall(dec.process, dec, '{"a":1}')
            if not ok then
                reentrant_err = err
            end

            ngx.thread.wait(co)

            assert(reentrant_err ~= nil, "the guard did not fire")
            assert(string.find(reentrant_err, "decode is not reentrant", 1, true),
                   "wrong error: " .. tostring(reentrant_err))

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



=== TEST 3: a returned error leaves the decoder usable and destroyable
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local decoder = require("resty.simdjson.decoder")

            for _, yieldable in ipairs({ true, false }) do
                local dec = decoder.new(yieldable)

                local res, err = dec:process('{"a":[1,2e]}')
                assert(res == nil)
                assert(err ~= nil)

                local ok = dec:process('{"a":[1,2]}')
                assert(ok.a[1] == 1, "reuse failed for yieldable="
                                     .. tostring(yieldable))

                dec:destroy()
            end

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
