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

=== TEST 1: example1 data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
{
    "glossary": {
        "title": "example glossary",
                "GlossDiv": {
            "title": "S",
                        "GlossList": {
                "GlossEntry": {
                    "ID": "SGML",
                                        "SortAs": "SGML",
                                        "GlossTerm": "Standard Generalized Mark up Language",
                                        "Acronym": "SGML",
                                        "Abbrev": "ISO 8879:1986",
                                        "GlossDef": {
                        "para": "A meta-markup language, used to create markup languages such as DocBook.",
                                                "GlossSeeAlso": ["GML", "XML"]
                    },
                                        "GlossSee": "markup"
                }
            }
        }
    }
}
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")
            assert(obj1.glossary.title == obj2.glossary.title)
            assert(obj1.glossary.GlossDiv.title == obj2.glossary.GlossDiv.title)
            assert(obj1.glossary.GlossDiv.GlossList.GlossEntry.GlossDef.GlossSeeAlso[1] ==
                   obj2.glossary.GlossDiv.GlossList.GlossEntry.GlossDef.GlossSeeAlso[1])

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



=== TEST 2: example2 data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
{"menu": {
  "id": "file",
  "value": "File",
  "popup": {
    "menuitem": [
      {"value": "New", "onclick": "CreateNewDoc()"},
      {"value": "Open", "onclick": "OpenDoc()"},
      {"value": "Close", "onclick": "CloseDoc()"}
    ]
  }
}}
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")
            assert(obj1.menu.id == obj2.menu.id)
            assert(obj1.menu.value == obj2.menu.value)

            assert(#obj1.menu.popup.menuitem == #obj2.menu.popup.menuitem)
            for i = 1, 3 do
                assert(obj1.menu.popup.menuitem[1].value == obj2.menu.popup.menuitem[1].value)
                assert(obj1.menu.popup.menuitem[1].onclick == obj2.menu.popup.menuitem[1].onclick)
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



=== TEST 3: example3 data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
{"widget": {
    "debug": "on",
    "window": {
        "title": "Sample Konfabulator Widget",
        "name": "main_window",
        "width": 500,
        "height": 500
    },
    "image": {
        "src": "Images/Sun.png",
        "name": "sun1",
        "hOffset": 250,
        "vOffset": 250,
        "alignment": "center"
    },
    "text": {
        "data": "Click Here",
        "size": 36,
        "style": "bold",
        "name": "text1",
        "hOffset": 250,
        "vOffset": 100,
        "alignment": "center",
        "onMouseUp": "sun1.opacity = (sun1.opacity / 100) * 90;"
    }
}}
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")
            assert(obj1.widget.debug == obj2.widget.debug)
            assert(obj1.widget.window.title == obj2.widget.window.title)
            assert(obj1.widget.image.name == obj2.widget.image.name)
            assert(obj1.widget.text.onMouseUp == obj2.widget.text.onMouseUp)

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



=== TEST 5: example5 data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
{"menu": {
    "header": "SVG Viewer",
    "items": [
        {"id": "Open"},
        {"id": "OpenNew", "label": "Open New"},
        null,
        {"id": "ZoomIn", "label": "Zoom In"},
        {"id": "ZoomOut", "label": "Zoom Out"},
        {"id": "OriginalView", "label": "Original View"},
        null,
        {"id": "Quality"},
        {"id": "Pause"},
        {"id": "Mute"},
        null,
        {"id": "Find", "label": "Find..."},
        {"id": "FindAgain", "label": "Find Again"},
        {"id": "Copy"},
        {"id": "CopyAgain", "label": "Copy Again"},
        {"id": "CopySVG", "label": "Copy SVG"},
        {"id": "ViewSVG", "label": "View SVG"},
        {"id": "ViewSource", "label": "View Source"},
        {"id": "SaveAs", "label": "Save As"},
        null,
        {"id": "Help"},
        {"id": "About", "label": "About Adobe CVG Viewer..."}
    ]
}}
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")
            assert(obj1.menu.header == obj2.menu.header)

            for i = 1, 22 do
                if obj1.menu.items[i] == ngx.null then
                    assert(obj1.menu.items[i] == obj2.menu.items[i])
                else
                    assert(obj1.menu.items[i].id == obj2.menu.items[i].id)
                    assert(obj1.menu.items[i].label == obj2.menu.items[i].label)
                end
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



=== TEST 6: number data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
[ 0.110001,
  0.12345678910111,
  0.412454033640,
  2.6651441426902,
  2.718281828459,
  3.1415926535898,
  2.1406926327793 ]
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")

            local nums = {
                0.110001,
                0.12345678910111,
                0.412454033640,
                2.6651441426902,
                2.718281828459,
                3.1415926535898,
                2.1406926327793,
            }

            for i, v in ipairs(nums) do
                assert(obj1[i] == obj2[i] and obj1[i] == v)
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



=== TEST 7: rfc-1 data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
{
   "Image": {
       "Width":  800,
       "Height": 600,
       "Title":  "View from 15th Floor",
       "Thumbnail": {
           "Url":    "http://www.example.com/image/481989943",
           "Height": 125,
           "Width":  "100"
       },
       "IDs": [116, 943, 234, 38793]
     }
}
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")
            assert(obj1.Image.Width == obj2.Image.Width)
            assert(obj1.Image.Height == obj2.Image.Height)
            assert(obj1.Image.Title == obj2.Image.Title)
            assert(obj1.Image.Thumbnail.Width == obj2.Image.Thumbnail.Width)
            assert(obj1.Image.Thumbnail.Height == obj2.Image.Thumbnail.Height)
            assert(obj1.Image.IDs[3] == obj2.Image.IDs[3])

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



=== TEST 8: rfc-2 data
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local str = [[
[
   {
      "precision": "zip",
      "Latitude":  37.7668,
      "Longitude": -122.3959,
      "Address":   "",
      "City":      "SAN FRANCISCO",
      "State":     "CA",
      "Zip":       "94107",
      "Country":   "US"
   },
   {
      "precision": "zip",
      "Latitude":  37.371991,
      "Longitude": -122.026020,
      "Address":   "",
      "City":      "SUNNYVALE",
      "State":     "CA",
      "Zip":       "94085",
      "Country":   "US"
   }
]
            ]]

            local simdjson = require("resty.simdjson")

            local parser = simdjson.new()
            assert(parser)

            local obj1 = parser:decode(str)
            local obj2 = parser:decode(parser:encode(obj1))

            assert(type(obj1) == "table" and type(obj2) == "table")

            local fields = {"precision", "Latitude", "Longitude", "Address",
                            "City", "State", "Zip", "Country",}

            for i, f in ipairs(fields) do
                assert(obj1[1][f] == obj2[1][f])
                assert(obj1[2][f] == obj2[2][f])
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



