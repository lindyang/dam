local mysql = require("resty.mysql")
local _M = { _VERSION = '1.0' }


function _M.get_conn()
    local db, err = mysql:new()
    if not db then
        error(
end


return _M


