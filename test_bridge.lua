local directory = (arg[0] or ''):match('^(.*[/\\])') or './'
package.path = directory .. '?.lua;' .. package.path
local http, bridge = require('http'), require('bridge')
local count = 0
local function test(name, fn)
  local ok, err = pcall(fn); assert(ok, name .. ': ' .. tostring(err))
  count = count + 1; print('ok ' .. count .. ' - ' .. name)
end
local function fixture(input)
  local state = {pos = 1, output = ''}
  local fd = {}
  function fd:settimeout(n) assert(n > 0); return 1 end
  function fd:receive(n)
    local chunk = input:sub(state.pos, state.pos + n - 1)
    state.pos = state.pos + #chunk
    if #chunk ~= n then return nil, 'closed', chunk end
    return chunk
  end
  function fd:send(data, pos)
    local last = math.min(pos + 3, #data)
    state.output = state.output .. data:sub(pos, last)
    return last
  end
  return fd, {gettime = function() return 100 end}, state
end
local function parse(input)
  local fd, socket = fixture(input)
  return http.read(fd, socket)
end
local function rejects(input) assert(not pcall(parse, input)) end

test('health request', function()
  local r = parse('GET /health HTTP/1.1\r\nHost: hub\r\n\r\n')
  assert(r.method == 'GET' and r.path == '/health' and r.body == '')
end)
test('bounded JSON body', function()
  local r = parse('POST /transmit HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}')
  assert(r.body == '{}')
end)
test('oversized or incomplete headers rejected', function()
  rejects('GET /health HTTP/1.1\r\nX: ' .. string.rep('a', 8192))
  rejects('GET /health HTTP/1.1\n\n')
  rejects('GET /health HTTP/1.1\r\nX: unfinished')
end)
test('ambiguous framing rejected', function()
  rejects('POST /transmit HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n')
  rejects('POST /transmit HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n')
  rejects('POST /transmit HTTP/1.1\r\nExpect: 100-continue\r\n\r\n')
  rejects('POST /transmit HTTP/1.1\r\nContent-Length: -1\r\n\r\n')
  rejects('POST /transmit HTTP/1.1\r\nContent-Length: 32769\r\n\r\n')
  rejects('POST /transmit HTTP/1.1\r\nContent-Length: 3\r\n\r\n{}')
end)
test('HTTP response partial writes', function()
  local fd, socket, state = fixture('')
  http.write(fd, socket, 200, '{}')
  assert(state.output:match('^HTTP/1.1 200 OK\r\n'))
  assert(state.output:find('Content%-Length: 2\r\n'))
  assert(state.output:sub(-4) == '\r\n{}')
end)

local request = {path = '/transmit', method = 'POST', headers = {['content-type'] = 'application/json'}, body = '{}'}
local function call(input, fail)
  local calls = 0
  local json = {decode = function() return input end, encode = function(value) return value end}
  local client = {transmit = function(_, _, payload, duration)
    calls = calls + 1
    assert(type(payload) == 'string' and duration > 0 and duration <= 1000000)
    if fail then error('HAL timeout; cancellation unconfirmed') end
  end}
  local code, body = bridge.handle(request, {}, json, client)
  return code, body, calls
end

test('health is unauthenticated and never contacts HAL', function()
  local code, body = bridge.handle({path = '/health', method = 'GET', body = ''}, {},
    {encode = function(v) return v end}, {transmit = function() error('must not transmit') end})
  assert(code == 200 and body.authenticated == false and body.api_version == 1)
end)
test('valid transmission', function()
  local code, body, calls = call({carrier_hz = 38000, timings_us = {560, -560}})
  assert(code == 200 and body.accepted and body.cancellation_acknowledged and calls == 1)
end)
test('malformed and oversized signals do not reach HAL', function()
  for _, input in ipairs({false, {}, {carrier_hz = 38000, timings_us = {0}},
    {carrier_hz = 38000, timings_us = {560, -1000000}},
    {carrier_hz = 1, timings_us = {560}},
    {carrier_hz = 38000, timings_us = {560}, duty_percent = false},
    {carrier_hz = 38000, timings_us = {560}, extra = true},
    {carrier_hz = 38000, timings_us = {foo = 560}}}) do
    local code, _, calls = call(input)
    assert(code == 400 and calls == 0)
  end
end)
test('no retry on HAL failure', function()
  local code, body, calls = call({carrier_hz = 38000, timings_us = {560}}, true)
  assert(code == 502 and body.transmission_uncertain and not body.retry_safe and calls == 1)
end)
test('browser form and cross-origin preflight rejected', function()
  local json = {encode = function(v) return v end}
  local code = bridge.handle({path = '/transmit', method = 'POST', body = '{}',
    headers = {['content-type'] = 'text/plain'}}, {}, json, {})
  assert(code == 415)
  code = bridge.handle({path = '/transmit', method = 'OPTIONS', body = '', headers = {}}, {}, json, {})
  assert(code == 405)
end)
test('unknown paths rejected', function()
  local code = bridge.handle({path = '/shell', method = 'POST'}, {},
    {encode = function(v) return v end}, {})
  assert(code == 404)
end)
test('immediate socket timeout waits for readability', function()
  local descriptor, socket = fixture('GET /health HTTP/1.1\r\nHost: hub\r\n\r\n')
  local receive = descriptor.receive
  local ready, waits = false, 0
  descriptor.receive = function(self, amount)
    if not ready then return nil, 'timeout', '' end
    return receive(self, amount)
  end
  socket.select = function(readable, _, timeout)
    assert(readable[1] == descriptor and timeout > 0)
    ready, waits = true, waits + 1
    return readable
  end
  assert(http.read(descriptor, socket).path == '/health' and waits == 1)
end)

local function capture_request(input, outcome, raw_body)
  local captures, transmissions = 0, 0
  local request = {path = '/capture', method = 'POST', body = raw_body or '{}',
    headers = {['content-type'] = 'application/json'}}
  local json = {decode = function() return input end, encode = function(value) return value end}
  local backend = {
    capture = function(_, _, timeout)
      captures = captures + 1
      if outcome == 'error' then error('capture transport failed') end
      if outcome == 'timeout' then return nil end
      return {decoder_version = 2, timings_us = {3300, -1600}, timeout_s = timeout}
    end,
    transmit = function() transmissions = transmissions + 1 end,
  }
  local status, response = bridge.handle(request, {}, json, backend)
  return status, response, captures, transmissions
end

test('capture accepts only bounded explicit windows and never sends', function()
  local status, response, captures, transmissions = capture_request({timeout_s = 3})
  assert(status == 200 and response.timeout_s == 3 and captures == 1 and transmissions == 0)
  status, response = capture_request({})
  assert(status == 200 and response.timeout_s == 10)
  for _, input in ipairs({{timeout_s = 0}, {timeout_s = 31}, {timeout_s = false},
    {timeout_s = 1.5}, {timeout_s = '10'}, {unknown = true}}) do
    status, _, captures, transmissions = capture_request(input)
    assert(status == 400 and captures == 0 and transmissions == 0)
  end
  status, _, captures = capture_request({}, nil, '[]')
  assert(status == 400 and captures == 0)
end)

test('capture timeout and transport failure remain distinct', function()
  local status, response, captures, transmissions = capture_request({}, 'timeout')
  assert(status == 504 and response.capture_timeout and captures == 1 and transmissions == 0)
  status, response, captures, transmissions = capture_request({}, 'error')
  assert(status == 502 and response.error and captures == 1 and transmissions == 0)
end)

print('Passed ' .. count .. ' bridge tests; no device I/O.')
