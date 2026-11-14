local directory = (arg[0] or ''):match('^(.*[/\\])') or './'
package.path = directory .. '?.lua;' .. package.path
local client, http, bridge = require('client'), require('http'), require('bridge')

local function run()
  local host, port = '127.0.0.1', 8089
  local index = 1
  while arg[index] do
    local name, value = arg[index], arg[index + 1]
    assert(value, 'missing option value')
    if name == '--listen' then host = value
    elseif name == '--port' then port = tonumber(value)
    else error('usage: lua server.lua [--listen IPv4] [--port PORT]') end
    index = index + 2
  end
  assert(host:match('^%d+%.%d+%.%d+%.%d+$'), 'listen address must be numeric IPv4')
  for octet in host:gmatch('%d+') do assert(tonumber(octet) <= 255, 'invalid IPv4 address') end
  assert(port and port == math.floor(port) and port >= 1024 and port <= 65535, 'invalid port')
  local socket, json, socket_source, json_source = client.modules()
  assert(socket, socket_source); assert(json, json_source)
  assert(type(json.encode) == 'function' and type(socket.sleep) == 'function', 'required module functions unavailable')
  local listener, err = socket.tcp()
  assert(listener, err)

  assert(listener:setoption('reuseaddr', true))
  assert(listener:bind(host, port))
  assert(listener:listen(1))
  print('Harmony IR bridge: http://' .. host .. ':' .. port)
  print('WARNING: NO AUTHENTICATION. Trusted LAN only; never port-forward this service.')
  print('IR capture available via POST /capture; no automatic replay.')
  print('Single worker; do not run CLI commands or other IR controllers concurrently.')
  io.stdout:flush()
  while true do
    local fd, accept_error = listener:accept()
    assert(fd, accept_error)
    local ok, problem = pcall(function()
      local parsed, request = pcall(http.read, fd, socket)
      local status, body
      if not parsed then status, body = 400, json.encode({error = tostring(request)})
      else status, body = bridge.handle(request, socket, json, client) end
      http.write(fd, socket, status, body)
    end)
    pcall(function() fd:close() end)
    if not ok then io.stderr:write('Request failed: ' .. tostring(problem) .. '\n') end
  end
end

local ok, err = pcall(run)
if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
