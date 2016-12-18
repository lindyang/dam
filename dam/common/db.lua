require("debug")
local mysql = require("resty.mysql")
local _M = { _VERSION = '1.0' }


function _M.get_conn(self)
    local db, err = mysql:new()
    if not db then
        error("failed to instantiate mysql: ", err)
        return
    end

    db:set_timeout(1000)  -- 1 sec

    local ok, err, errcode, sqlstate = db:connect{
        host = "127.0.0.1",
        port = 3306,
        database = "beehive_test",
        password = "",
        max_packet_size = 1024 * 1024
    }
    if not ok then
        error("failed to connect: ", err, ": ", errcode, " ", sqlstate)
        return
    end
    log("connect to mysql.")

    function db:close()
        local ok, err = db:set_keepalive(
            tonumber(ngx.var.MYSQL_CONN_IDLE_TIMEOUT),
            tonumber(ngx.var.MYSQL_CONN_POOL_SIZE)
        )
        if not ok then
            error(err)
            return
        end
    end

    return db
end


return _M


