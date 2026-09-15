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


=== TEST 1: mutated input never corrupts a shared decoder
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local decoder = require("resty.simdjson.decoder")

            -- fixed seed, so a failure is reproducible from the log
            local SEED = 20250915
            math.randomseed(SEED)

            local seeds = {
                '{"a":[1,2,3],"b":{"c":"d"},"e":null}',
                '[1,-2,3.5,1e3,true,false,null]',
                '{"nested":{"deep":{"deeper":[{"x":1},{"y":"z"}]}}}',
                '{"s":"with \\"escapes\\" and \\u00e9"}',
                '[[[[1]]]]',
                '{"big":1e308,"small":1e-308}',
                '[]',
                '{}',
            }

            -- the decoder must still return this correctly after every mutation
            local CANARY = '{"canary":[1,2],"ok":{"v":3}}'

            -- one decoder for the whole run, which is the point of the test
            local dec = decoder.new(false)

            local function dec_process(json)
                local ok, res, err = pcall(dec.process, dec, json)
                -- a raise means the decoder handed back inconsistent state
                assert(ok, "process() raised on " .. string.format("%q", json)
                           .. ": " .. tostring(res))
                return res, err
            end

            local function check_canary(step)
                local res, err = dec_process(CANARY)
                assert(err == nil, step .. ": canary failed: " .. tostring(err))
                assert(res.canary[1] == 1, step .. ": canary[1] wrong")
                assert(res.canary[2] == 2, step .. ": canary[2] wrong")
                assert(res.ok.v == 3, step .. ": canary ok.v wrong")
            end

            local function mutate(s)
                local kind = math.random(4)
                local i = math.random(#s)

                if kind == 1 then          -- truncate
                    return string.sub(s, 1, i)
                elseif kind == 2 then      -- flip one byte
                    return string.sub(s, 1, i - 1)
                           .. string.char(math.random(0, 255))
                           .. string.sub(s, i + 1)
                elseif kind == 3 then      -- delete one byte
                    return string.sub(s, 1, i - 1) .. string.sub(s, i + 1)
                end
                                           -- duplicate one byte
                return string.sub(s, 1, i) .. string.sub(s, i, i)
                       .. string.sub(s, i + 1)
            end

            check_canary("before")

            local decoded, errored = 0, 0

            for round = 1, 2000 do
                local seed = seeds[math.random(#seeds)]
                local input = mutate(seed)

                local res, err = dec_process(input)

                -- either it decodes or it reports an error, never both, and
                -- never a partial value with an error attached
                if err then
                    assert(res == nil,
                           "round " .. round .. ": value returned with an error")
                    errored = errored + 1
                else
                    decoded = decoded + 1
                end

                check_canary("round " .. round)
            end

            dec:destroy()

            -- a run where nothing failed would not test anything
            assert(errored > 100, "too few rejected inputs: " .. errored)

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
