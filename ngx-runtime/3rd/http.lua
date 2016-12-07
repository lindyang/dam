local http_headers = require "resty.http_headers"

local ngx_socket_tcp = ngx.socket.tcp
local ngx_req = ngx.req
local ngx_req_socket = ngx.req.socket
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_get_method = ngx.req.get_method
local str_gmatch = string.gmatch
local str_lower = string.lower
local str_upper = string.upper
local str_find = string.find
local str_sub = string.sub
local str_gsub = string.gsub
local tbl_concat = table.concat
local tbl_insert = table.insert
local ngx_encode_args = ngx.encode_args
local ngx_re_match = ngx.re.match
local ngx_re_gsub = ngx.re.gsub
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_NOTICE = ngx.NOTICE
local ngx_var = ngx.var
local co_yield = coroutine.yield
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume



--
local HOP_BY_HOP_HEADERS = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailers"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
    ["content-length"] = true,  -- Not strictly hop-by-hop, but Nginx will deal
                                -- with this (may send chunked for example).
}


-- Reimplemented coroutine.wrap, returning "nil, err" if the coroutine cannot
-- be resumed. This protects user code from inifite loops when doing things like repeat
--  local chunk, err = res.body_reader()
--  if chunk then -- <-- This could be a string msg in the core wrap function
--      ...
--  end
--  until not chunk
local co_wrap = function(func)
    local co = co_create(func)
    if not co then
        return nil, "could not create coroutine"
    else
        return function(...)
            if co_status(co) == "suspended" then
                return select(2, co_resume(co, ...))
            else
                return nil, "can't resume a " .. co_status(co) .. " coroutine"
            end
        end
    end
end


local _M = {
    _VERSION = '0.08',
}

_M._USER_AGENT = "lua-resty-http/" .. M._VERSION .. " (Lua) ngx_lua/" .. ngx.config.ngx_lua_version

local mt = {__index = _M}

local HTTP = {
    [1.0] = " HTTP/1.0\r\n",
    [1.1] = " HTTP/1.1\r\n",
}

local DEFAULT_PARAMS = {
    method = "GET",
    path = "/",
    version = 1.1,
}

function _M.new(self)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return  nil, err
    end
    return setmetatable({sock=sock, keepalive=true}, mt)
end


function _M.set_timeout(self, timeout)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    return sock:settimeout(timeout)
end


function _M.ssl_handshake(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    self.ssl = true
    return sock:sslhandshake(...)
end


function _M.connect(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    self.host = select(1, ...)
    self.port = select(2, ...)
    -- If port is not a number, this is likely a unix domain socket connection.
    if type(self.port) ~= "number" then
        self.port = nil
    end
    self.keepalive = true
    return sock.connect(...)
end


function _M.set_keepalive(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    if self.keepalive == true then
        return sock:setkeepalive(...)
    else
        -- The server said we must close the connection, so we cannot setkeepalive
        -- If close() succeeds we return 2 instead of 1, to differentiate between
        -- a normal setkeepalive() failure and an intentional close().
        local res, err = sock:close()
        if res then
            return 2, "connection must be closed"
        else
            return res, err
        end
    end
end


function _M.get_reused_times(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    return sock:getreusedtimes()
end


function _M:close(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    return sock:close()
end


local function _should_receive_body(method, code)
    if method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return true
end


function _M.parse_uri(self, uri)
    local m, err = ngx_re_match(uri, [[^(http[s]*)://([^:/]+)(?::(\d+))?(.*)]], "jo")
    if not m then
        if err then
            return nil, "failed to match the uri: " .. err
        end
        return nil, "bad uri"
    else
        if m[3] then
            m[3] = tonumber(m[3])
        else
            if m[1] == "https" then
                m[3] = 443
            else
                m[3] = 80
            end
        end
        if not m[4] or "" == m[4] then m[4] = "/" end
        return m, nil
    end
end


local function _format_request(params)
    local version = params.version
    local headers = params.headers or {}
    local query = params.query or ""
    if query then
        if type(query) == "table" then
            query = "?" .. ngx_encode_args(query)
        end
    end

    -- Initialize request
    local req = {
        str_upper(params.method),
        " ",
        params.path,
        query,
        HTTP[version],
        -- Pre-allocate slots for minimum headers and carriage return.
        true,
        true,
        true,
    }
    local c = 6  -- req table index it's faster to do this inline vs table.insert

    -- Append headers
    for key, values in pairs(headers) do
        if type(values) ~= "table" then
            values = {values}
        end

        key = tostring(key)
        for _, value in pairs(values) do
            req[c] = key .. ": " .. tostring(value) .. "\r\n"
            c = c + 1
        end
    end

    -- Close headers
    req[c] = "\r\n"
    return tbl_concat(req)
end


local function _receive_status(sock)
    local line, err = sock:receive("*l")
    if not line then
        return nil, nil, nil, err
    end
    return tonumber(str_sub(line, 10, 12)), tonumber(str_sub(line, 6, 8)), str_sub(line, 14)
end


local function _receive_headers(sock)
    local headers = http_headers.new()
    repeat
        local line, err = sock:receive("*l")
        if not line then
            return nil, err
        end

        for key, val in str_gmatch(line, "([^:%s]+):%s*(.+)") do
            if headers[key] then
                if type(headers[key]) ~= "table" then
                    headers[key] = { headers[key] }
                end
                tbl_insert(headers[key], tostring(val))
            else
                headers[key] = tostring(val)
            end
        end
    until str_find(line, "^%s*$")
    return headers, nil
end


local function _chunked_body_reader(sock, default_chunk_size)
    
    
