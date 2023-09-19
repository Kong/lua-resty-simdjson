local decoder = require("resty.simdjson.decoder")
local encoder = require("resty.simdjson.encoder")


local _M = {}
local _MT = { __index = _M, }


local setmetatable = setmetatable


function _M.new(yieldable)
    local self = {
      decoder = decoder.new(yieldable),
      encoder = encoder.new(yieldable),
    }

    return setmetatable(self, _MT)
end


function _M:destroy()
    self.decoder:destroy()
end


function _M:decode(json)
    return self.decoder:process(json)
end


function _M:encode(item)
    return self.encoder:process(item)
end


function _M:encode_number_precision(precision)
    return self.encoder:encode_number_precision(precision)
end


function _M:encode_sparse_array(convert)
    return self.encoder:encode_sparse_array(convert)
end


return _M
