require("global")
local db = require("db")
local os = require("os")


local args = ngx.req.get_uri_args()
local start = args['start']
local end = args['end']
local symbol = args['symbol']
local marketid = args['marketid'] or 0
local hack = args['hack']

