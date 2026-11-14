local directory = (arg[0] or ''):match('^(.*[/\\])') or './'
package.path = directory .. '?.lua;' .. package.path
local ir = require('ir')
local client = require('client')

local function run()
  local mode = arg[1]
  if mode == '--probe' and not arg[2] then
    local socket, json, socket_source, json_source = client.modules()
    print('Lua: ' .. _VERSION)
    print('Socket: ' .. (socket and 'available via ' or 'UNAVAILABLE: ') .. socket_source)
    print('JSON: ' .. (json and 'available via ' or 'UNAVAILABLE: ') .. json_source)
    print('No sockets connected, IR sent, or stock application tasks started.')
    assert(socket and json and type(socket.sleep) == 'function', 'required modules unavailable')
    return
  end
  if mode == '--stop' and not arg[2] then
    local socket, json, socket_source, json_source = client.modules()
    assert(socket, socket_source)
    assert(json, json_source)
    local raw = client.exchange(socket, ir.request(nil, false, 2))

    print('HAL cancellation reply: ' .. raw)
    client.check_reply(json, raw, 2)
    print('Cancellation acknowledged. No IR signal was submitted.')
    return
  end
  assert((mode == '--dry-run' or mode == '--send') and arg[2] and arg[3] and not arg[4],
    'usage: lua transmit.lua --probe | --stop | --dry-run HZ TIMINGS.txt | --send HZ TIMINGS.txt')
  local f = assert(io.open(arg[3], 'rb'))
  local text = f:read(32769)
  f:close()
  assert(text and #text <= 32768, 'timing file empty or larger than 32 KiB')
  local timings = {}
  for token in text:gmatch('%S+') do
    assert(token:match('^[+-]?%d+$'), 'expected whitespace-separated signed integer timings')
    timings[#timings + 1] = assert(tonumber(token))
    assert(#timings <= 2048, 'too many timings')
  end
  local payload, duration = ir.encode(tonumber(arg[2]), timings)
  if mode == '--dry-run' then
    print('Duration (us): ' .. duration)
    print('IR payload hex: ' .. ir.hex(payload))
    print('LTCP request hex: ' .. ir.hex(ir.frame(ir.request(payload, true, 1))))
    print('Dry run: no native modules loaded, connections opened, or IR transmitted.')
    return
  end
  local socket, json, socket_source, json_source = client.modules()
  assert(socket, socket_source)
  assert(json, json_source)
  assert(type(socket.sleep) == 'function', 'socket.sleep unavailable')
  io.stderr:write('EXPERIMENTAL: transmitting on all IR outputs; no automatic retries.\n')
  local sent, canceled = client.transmit(socket, json, payload, duration)
  print('HAL accepted request: ' .. sent)
  print('HAL acknowledged cancellation: ' .. canceled)
  print('This does not prove that the appliance received the signal.')
end

local ok, err = pcall(run)
if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
