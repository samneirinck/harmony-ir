local directory = (arg[0] or ''):match('^(.*[/\\])') or './'
package.path = directory .. '?.lua;' .. package.path
local ir, client = require('ir'), require('client')
local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  assert(ok, name .. ': ' .. tostring(err))
  count = count + 1
  print('ok ' .. count .. ' - ' .. name)
end
local function rejects(fn) assert(not pcall(fn), 'expected rejection') end
local function reply(payload)
  local out = ir.frame(payload)
  return out:sub(1, 2) .. string.char(128) .. out:sub(4)
end

test('known binary encoding matches native format', function()
  local data, duration = ir.encode(40000, {750, -750}, 50)
  assert(ir.hex(data) == '01000061a83200000000001000000000000282ee02ee')
  assert(duration == 1500)
end)
test('38 kHz period and long-space splitting', function()
  local data = ir.encode(38000, {560, -100000})
  assert(ir.hex(data) == '01000066cc2100000000001000000000000582307fff7fff7fff06a3')
end)
test('invalid timing and carrier inputs', function()
  for _, timings in ipairs({{}, {0}, {-560}, {560, 1.5}, {560, -1000000}}) do
    rejects(function() ir.encode(38000, timings) end)
  end
  for _, frequency in ipairs({0, -1, 9999, 60001, 38000.5}) do
    rejects(function() ir.encode(frequency, {560}) end)
  end
  rejects(function() ir.encode(38000, {560}, 51) end)
end)
test('request envelope has no binary terminator', function()
  local request = ir.request('abc', true, 1)
  assert(request:match('"enable":true'))
  assert(request:sub(-4) == '}abc')
  assert(ir.request(nil, false, 2):match('"id":2'))
end)
test('short and long LTCP length encoding and padding', function()
  local short = ir.frame('abc')
  assert(#short == 64)
  assert(ir.hex(short:sub(1, 8)) == 'ff08000101020183')
  local long = ir.frame(string.rep('a', 300))
  assert(#long == 320)
  assert(ir.hex(long:sub(7, 9)) == '01c12c')
  rejects(function() ir.frame('') end)
  rejects(function() ir.frame(string.rep('a', 16384)) end)
end)
test('reply decoding from arbitrary truncated buffers', function()
  local payload = '{"id":1,"code":200}'
  local response = reply(payload)
  for i = 0, 8 + #payload - 1 do
    local decoded, err = ir.reply(response:sub(1, i))
    assert(not decoded and err == 'incomplete')
  end
  assert(ir.reply(response).payload == payload)
end)
test('long reply', function()
  local payload = string.rep('x', 1000)
  assert(ir.reply(reply(payload)).payload == payload)
end)
test('padding between primary and secondary', function()
  local response = reply('abc')
  response = response:sub(1, 6) .. string.rep('\0', 58) .. response:sub(7)
  assert(ir.reply(response).payload == 'abc')
end)
test('response-bit secondary IDs and unflagged short lengths', function()
  local payload = '{"id":2,"code":200}'

  for _, length_flag in ipairs({0, 128}) do
    local wire = string.char(255, 8, 128, 1, 1, 2, 129, #payload + length_flag) .. payload
    assert(ir.reply(wire).payload == payload)
  end
end)
test('response-bit secondary IDs and extended lengths', function()
  local payload = string.rep('x', 300)
  for _, length_flag in ipairs({0, 128}) do
    local wire = string.char(255, 8, 128, 1, 1, 2, 129, 65 + length_flag, 44) .. payload
    assert(ir.reply(wire).payload == payload)
  end
end)
test('reserved secondary sequence bit rejected', function()
  local wire = string.char(255, 8, 128, 1, 1, 2, 65, 131) .. 'abc'
  local result, err = ir.reply(wire)
  assert(not result and err:match('invalid secondary sequence'))
end)
test('bad protocol and request IDs rejected', function()
  assert(not ir.reply('bad!'))
  local response = ir.frame('abc')
  assert(not ir.reply(response))
  response = string.char(255, 8, 255, 1, 1, 2)
  assert(not ir.reply(response))
end)

local function socket_fixture(response, fail_send)
  local state = {closed = false, sent = '', index = 1}
  local fd = {}
  function fd:settimeout(n) assert(n > 0); return 1 end
  function fd:connect(host, port)
    assert(host == '127.0.0.1' and port == 16716); return 1
  end
  function fd:send(data, start)
    if fail_send then return nil, 'closed' end
    local last = math.min(start + 6, #data)
    state.sent = state.sent .. data:sub(start, last)
    return last
  end
  function fd:receive(n)
    local chunk = response:sub(state.index, state.index + n - 1)
    state.index = state.index + #chunk
    if #chunk < n then return nil, 'closed', chunk end
    return chunk
  end
  function fd:close() state.closed = true end
  local socket = {gettime = function() return 100 end, tcp = function() return fd end}
  return socket, state
end

test('partial socket writes and final partial reads', function()
  local wire = reply('{"id":1,"code":200}'):sub(1, 27)
  local socket, state = socket_fixture(wire)
  assert(client.exchange(socket, 'request') == '{"id":1,"code":200}')
  assert(state.closed)
  assert(state.sent == string.char(6) .. ir.frame('request'))
end)
test('socket closed on send failure without retry', function()
  local socket, state = socket_fixture('', true)
  rejects(function() client.exchange(socket, 'request') end)
  assert(state.closed and state.sent == '')
end)
test('JSON reply status and ID validation', function()
  local json = {decode = function() return {id = 1, code = 200} end}
  assert(client.check_reply(json, 'reply', 1))
  rejects(function() client.check_reply(json, 'reply', 2) end)
  for _, code in ipairs({0, 201, 400, 500}) do
    json.decode = function() return {id = 1, code = code} end
    rejects(function() client.check_reply(json, 'reply', 1) end)
  end
end)
test('cancellation attempted after uncertain transmission', function()
  local old_exchange, calls = client.exchange, {}
  client.exchange = function(_, request)
    calls[#calls + 1] = request
    if #calls == 1 then error('timeout after write') end
    return 'cancel reply'
  end
  local json = {decode = function() return {id = 2, code = 200} end}
  local ok, err = pcall(client.transmit, {sleep = function() end}, json, 'payload', 1000)
  client.exchange = old_exchange
  assert(not ok and tostring(err):match('cancellation acknowledged'))
  assert(#calls == 2 and calls[2]:match('"enable":false'))
end)
test('successful send waits then cancels', function()
  local old_exchange, calls, slept = client.exchange, {}, false
  client.exchange = function(_, request)
    calls[#calls + 1] = request
    return tostring(#calls)
  end
  local json = {decode = function(raw) return {id = tonumber(raw), code = 200} end}
  local socket = {sleep = function(seconds) assert(seconds >= 0.051); slept = true end}
  local ok, err = pcall(client.transmit, socket, json, 'payload', 1000)
  client.exchange = old_exchange
  assert(ok, err)
  assert(slept and #calls == 2)
end)
test('LG power examples encode the expected keycodes and timings', function()
  for name, expected in pairs({on = '20DF23DC', off = '20DFA35C'}) do
    local f = assert(io.open(directory .. 'examples/lg-power-' .. name .. '.txt', 'r'))
    local text = f:read('*a'); f:close()
    local timings, total = {}, 0
    for value in text:gmatch('%S+') do
      local n = assert(tonumber(value))
      timings[#timings + 1] = n
      total = total + math.abs(n)
    end
    assert(#timings == 72 and total == 215735)
    assert(timings[1] == 8990 and timings[2] == -4490)
    local key = 0
    for bit = 1, 32 do
      assert(timings[bit * 2 + 1] == 568)
      local space = timings[bit * 2 + 2]
      assert(space == -552 or space == -1662)
      key = key * 2 + (space == -1662 and 1 or 0)
    end
    assert(string.format('%08X', key) == expected)
    assert(timings[67] == 568 and timings[68] == -40222)
    assert(timings[69] == 8990 and timings[70] == -2230)
    assert(timings[71] == 568 and timings[72] == -96077)
    local _, duration = ir.encode(38000, timings)
    assert(duration == total)
  end
end)
print('Passed ' .. count .. ' offline tests; no device I/O.')
