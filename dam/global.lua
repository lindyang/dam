_G.print = ngx.print 
_G.say = ngx.say
_G.log = function (value, level) 
    local level = level or ngx.DEBUG
    if "table" == type(value) then
        local val = {}
        for k, v in pairs(value) do
            table.insert(val, "\t" .. k .. " = " .. v .. ",\n")
        end
        ngx.log(level, "\n[\n" .. table.concat(val) .. "]")
    else
        ngx.log(level, value)
    end
end

