local directory = (arg[0] or ''):match('^(.*[/\\])') or './'
package.path = directory .. '?.lua;' .. package.path
local client = require('client')

local function run()
  assert(not arg[1] or (arg[1] == '--timeout' and arg[2] and not arg[3]),
    'usage: lua capture.lua [--timeout SECONDS]')
  local timeout = 10
  if arg[1] then timeout = tonumber(arg[2]) end
  assert(timeout and timeout == math.floor(timeout) and timeout >= 1 and timeout <= 30,
    'capture timeout must be 1..30 seconds')
  local socket, json, socket_source, json_source = client.modules()
  assert(socket, socket_source); assert(json, json_source)
  assert(type(json.encode) == 'function', 'JSON encoder unavailable')
  io.stderr:write('EXPERIMENTAL: keep all IR controllers idle. Do not run alongside the bridge.\n'
    .. 'Aim the original remote at the Hub learning receiver and press once; do not hold.\n'
    .. 'Listening for up to ' .. timeout .. ' seconds. No IR will be transmitted.\n')
  local captured = client.capture(socket, json, timeout)
  assert(captured, 'capture timed out; connection closed to abort the native capture')
  print(json.encode(captured))
end

local ok, err = pcall(run)
if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
